#!/usr/bin/perl
use strict;
use warnings;
use utf8;

# 参考:
#   http://mattn.kaoriya.net/software/lang/perl/20081027121909.htm

use FindBin qw($Bin);
use Net::Twitter;
use YAML;
use DBD::SQLite;
use WWW::NicoVideo::Download;
use HTTP::Cookies;
use XML::Simple;
use IPC::Run qw(run timeout);
use HTML::Entities;

binmode STDOUT, ':encoding(utf8)';
select(STDOUT); $| = 1;

my $conf = &load_config;

my $dbh = DBI->connect(
    'dbi:SQLite:dbname=' . $conf->{db},
    '', '', {unicode => 1}
);
$dbh->func(5000, 'busy_timeout');

my $twit = Net::Twitter->new(
    username => $conf->{twitter}->{username},
    password => $conf->{twitter}->{password},
);

my $cookie_jar = HTTP::Cookies->new(file => $conf->{dirs}->{data} . '/cookies.txt', autosave => 1);
my $nv = WWW::NicoVideo::Download->new(
    email => $conf->{nicovideo}->{email},
    password => $conf->{nicovideo}->{password},
);
$nv->user_agent->cookie_jar($cookie_jar);
$nv->user_agent->timeout(30);

my @files = ();
my $sth = $dbh->prepare(
    'SELECT id, url, try FROM files WHERE filename IS NULL'
);
$sth->execute;
while(my $row = $sth->fetchrow_hashref)
{
    push(@files, $row);
}
$sth->finish; undef $sth;

$sth = $dbh->prepare(
    'UPDATE files SET title = ?, filename = ?, try = try + 1 WHERE id = ?'
);
my $n = 0;
foreach my $f (@files)
{
    $n++;
    printf "%s\n[%d/%d] (take %d) %d: %s\n",
        '-' x 78, $n, ($#files+1), $f->{try}+1, $f->{id}, $f->{url};

    if($f->{url} =~ m{^http://www\.nicovideo\.jp/watch/(\w{2}\d+)$})
    {
        my $result = 0;
        my $res = &fetch_nicovideo($1);
        print Dump($res);
        if(defined($res))
        {
            if($res->{status} eq 'ok')
            {
                if($res->{embeddable} == 1)
                {
                    $result = 1;
                    if($res->{downloaded} == 1) { sleep 5; }
                }
            }
        }

        printf "updating db ...\n";
        $dbh->begin_work;
        if($result == 1)
        {
            $sth->execute(
                $res->{title},
                $res->{filename},
                $f->{id},
            );
        }
        else
        {
            $sth->execute(
                undef,
                undef,
                $f->{id},
            );
        }
        $dbh->commit;
        printf "[%d/%d] done.\n", $n, ($#files+1);
    }
}
$sth->finish; undef $sth;

$dbh->begin_work;
$dbh->do(
    'DELETE FROM programs WHERE file_id IN ' .
    '(SELECT id FROM files WHERE filename IS NULL AND try >= 3)'
);
$dbh->do('DELETE FROM files WHERE filename IS NULL AND try >= 3');
$dbh->commit;


sub fetch_nicovideo
{
    my $video_id = shift || return undef;

    printf "target: %s\n", $video_id;

    foreach(@{$conf->{nglist}})
    {
        if($video_id =~ /^$_$/i)
        {
            printf "ERROR: $video_id is in NGlist, skip.\n";
            return undef;
        }
    }

    my $res = $nv->user_agent->get(
        'http://www.nicovideo.jp/api/getthumbinfo/' . $video_id
    );
    if($res->is_error)
    {
        printf "ERROR: get api failed\n";
        return undef;
    }

    my $xs = XML::Simple->new;
    my $x = $xs->XMLin($res->decoded_content);
    if($x->{status} ne 'ok')
    {
        printf "ERROR: status NG\n";
        return { status => $x->{status} };
    }

    $x->{thumb}->{title} = decode_entities($x->{thumb}->{title});
    printf "%s\n", $x->{thumb}->{title};
 
    if($x->{thumb}->{embeddable} == 0)
    {
        printf "ERROR: not embeddable\n";
        return {
            status => $x->{status},
            embeddable => $x->{thumb}->{embeddable},
            title => $x->{thumb}->{title},
        };
    }

    #print Dump($x);

    # タグの存在をチェック

    printf "checking tags ...\n";
    my @tags = ();
    if(ref($x->{thumb}->{tags}) eq 'ARRAY')
    {
        foreach my $d (@{$x->{thumb}->{tags}})
        {
            printf "  domain: %s\n", $d->{domain};
            if(ref($d->{tag}) eq 'ARRAY')
            {
                foreach(@{$d->{tag}})
                {
                    push(@tags, $_);
                }
            }
            else
            {
                push(@tags, $d->{tag});
            }
        }
    }
    else
    {
        if(ref($x->{thumb}->{tags}->{tag}) eq 'ARRAY')
        {
            foreach(@{$x->{thumb}->{tags}->{tag}})
            {
                push(@tags, $_);
            }
        }
        else
        {
            push(@tags, $x->{thumb}->{tags}->{tag});
        }
    }

    my @check_tags = (
        { expr => $conf->{tagcheck_expr}, found => 0 },
        { expr => '^音楽$', found => 0 },
    );
    foreach my $tag (@tags)
    {
        my $t = $tag;
        if(ref($tag) eq 'HASH')
        {
            $t = $tag->{content};
            printf "  * %s\n", $t;
        }
        else
        {
            printf "    %s\n", $t;
        }
        $t =~ tr/Ａ-Ｚａ-ｚ/A-Za-z/;
        foreach(@check_tags)
        {
            my $expr = $_->{expr};
            if($t =~ /$expr/i)
            {
                $_->{found} = 1;
            }
        }
    }

    my $tags_found = 1;
    foreach(@check_tags)
    {
        if($_->{found} == 0)
        {
            $tags_found = 0;
        }
    }

    # ホワイトリストにあるものは許可
    foreach(@{$conf->{whitelist}})
    {
        if($video_id =~ /^$_$/i)
        {
            $tags_found = 1;
        }
    }

    if($tags_found == 0)
    {
        printf "ERROR: required tags not found\n";
        return undef;
    }

    my $file_source = sprintf "%s/%s", $conf->{dirs}->{sources}, $video_id;
    printf "source: %s\n", $file_source;
    my $downloaded = 0;
    if(!-f $file_source)
    {
        printf "downloading ...\n";
        my $start_time = time;
        eval {
            $nv->download($video_id, $file_source . '.tmp');
        };
        if($@)
        {
            printf "ERROR: %s\n", $@;
            return undef;
        }
        printf "done, takes %d seconds\n", (time - $start_time);
        rename $file_source . '.tmp', $file_source;
        $downloaded = 1;
    }
    if(!-f $file_source || -z $file_source)
    {
        printf "ERROR: missing source file\n";
        return undef;
    }


    my $filename_song = $video_id . '.ogg';
    my $file_song = sprintf "%s/%s", $conf->{dirs}->{songs}, $filename_song;
    my $title = sprintf "%s (from http://www.nicovideo.jp/watch/%s)", $x->{thumb}->{title}, $video_id;

    printf "converting %s ...\n", $title;
    my ($out, $err);
    if($video_id =~ /^nm/)
    {
        run ["cat", $file_source], '|',
            ["$Bin/cws2fws.pl"], '|',
            [$conf->{cmds}->{ffmpeg},
             '-i', '-',
             '-vn',
             '-ac', 2,
             '-ar', 44100,
             '-f', 'wav',
             '-'], '|',
            [$conf->{cmds}->{oggenc},
             '-Q',
             '-t', $title,
             '-q', $conf->{converter}->{quality},
             '-o', $file_song, '-'],
            \$out, \$err, timeout(300) or die "$?";
    }
    else
    {
        run [$conf->{cmds}->{ffmpeg},
             '-i', $file_source,
             '-vn',
             '-ac', 2,
             '-ar', 44100,
             '-f', 'wav',
             '-'], '|',
            [$conf->{cmds}->{oggenc},
             '-Q',
             '-t', $title,
             '-q', $conf->{converter}->{quality},
             '-o', $file_song, '-'],
            \$out, \$err, timeout(300) or die "$?";
    }
    print $err;
    if(!-f $file_song)
    {
        printf "ERROR: failed to convert\n";
        return undef;
    }

    printf "running VorbisGain ...\n";
    # set VorbisGain tags
    run [$conf->{cmds}->{vorbisgain}, '-q', $file_song],
        \$out, \$err, timeout(60) or die "$?";

    printf "done.\n";
    return {
        status => $x->{status},
        embeddable => $x->{thumb}->{embeddable},
        title => $x->{thumb}->{title},
        filename => $filename_song,
        downloaded => $downloaded,
    };
}

sub load_config
{
    my $conffile = shift || $Bin . '/../conf/icesradio.conf';

    open FH, '<:encoding(utf8)', $conffile or return undef;
    my $yaml = join('', <FH>);
    close FH;

    my $conf = YAML::Load($yaml) or return undef;
    return $conf;
}

