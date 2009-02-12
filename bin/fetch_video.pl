#!/usr/bin/perl
use strict;
use warnings;
use utf8;

# 参考:
#   http://mattn.kaoriya.net/software/lang/perl/20081027121909.htm

use FindBin qw($Bin);
use FindBin::libs;

use Net::Twitter;
use YAML;
use DBD::SQLite;
use WWW::NicoVideo::Download;
use HTTP::Cookies;
use XML::Simple;
use IPC::Run qw(run timeout);
use HTML::Entities;

use VocaloidFM;
use VocaloidFM::Download;

binmode STDOUT, ':encoding(utf8)';
select(STDOUT); $| = 1;

my $conf = load_config;

my $dbh = DBI->connect(
    'dbi:SQLite:dbname=' . $conf->{db},
    '', '', {unicode => 1}
);
$dbh->func(5000, 'busy_timeout');

my $twit = Net::Twitter->new(
    username => $conf->{twitter}->{username},
    password => $conf->{twitter}->{password},
);

my $dl = VocaloidFM::Download->new;

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
    'UPDATE files SET title = ?, filename = ?, username = ?, ' .
    'try = try + 1 WHERE id = ?'
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
                $res->{username},
                $f->{id},
            );
        }
        else
        {
            $sth->execute(
                undef,
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

    my $x = $dl->get_thumbinfo($video_id);
    if(!defined($x))
    {
        printf "ERROR: getthumbinfo failed\n";
        return undef;
    }
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

    # タグを取得してチェック
    printf "checking tags ...\n";
    my $tags = VocaloidFM::Download::get_tags($x);
    my @tags_checked = (
        { type => 1,  expr => '^音楽$', found => 0 },
        { type => 1,  expr => $conf->{tagcheck}->{required}, found => 0 },
        { type => -1, expr => $conf->{tagcheck}->{ng}, found => 0 },
    );
    foreach my $tag (@{$tags})
    {
        printf "  [%s] %s %s\n",
            $tag->{domain}, ($tag->{lock} == 1 ? '*' : ' '), $tag->{content};
        my $t = $tag->{content};
        $t =~ tr/Ａ-Ｚａ-ｚ/A-Za-z/;
        foreach(@tags_checked)
        {
            my $expr = $_->{expr};
            if($t =~ /$expr/i)
            {
                $_->{found} = 1;
            }
        }
    }

    my $tags_ok = 1;
    foreach(@tags_checked)
    {
        if(($_->{type} == 1 && $_->{found} == 0) ||
           ($_->{type} == -1 && $_->{found} == 1))
        {
            $tags_ok = 0;
            last;
        }
    }

    # ホワイトリストにあるものは許可
    foreach(@{$conf->{whitelist}})
    {
        if($video_id =~ /^$_$/i)
        {
            $tags_ok = 1;
        }
    }

    if($tags_ok == 0)
    {
        printf "ERROR: NG due to tags \n";
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
            #$nv->download($video_id, $file_source . '.tmp');
            $dl->download($video_id, $file_source . '.tmp');
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
        my $tmpswf = $file_source . '.tmp.swf';
        run ["$Bin/cws2fws.pl"], '<', $file_source, '>', $tmpswf;
        run [$conf->{cmds}->{ffmpeg},
             '-i', $tmpswf,
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
        eval { unlink($tmpswf); };
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

    # 投稿者名取得テスト
    my $username = $dl->get_username($video_id);

    return {
        status => $x->{status},
        embeddable => $x->{thumb}->{embeddable},
        title => $x->{thumb}->{title},
        filename => $filename_song,
        downloaded => $downloaded,
        username => $username,
    };
}

