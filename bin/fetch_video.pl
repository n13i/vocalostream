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
#use FFmpeg::Command;
use IPC::Run qw(run timeout);

binmode STDOUT, ':encoding(utf8)';

my $conf = &load_config;

my $dbh = DBI->connect(
    'dbi:SQLite:dbname=' . $Bin . '/../' . $conf->{db},
    '', '', {unicode => 1}
);

my $twit = Net::Twitter->new(
    username => $conf->{twitter}->{username},
    password => $conf->{twitter}->{password},
);

my $cookie_jar = HTTP::Cookies->new(file => $Bin . '/../data/cookies.txt', autosave => 1);
my $nv = WWW::NicoVideo::Download->new(
    email => $conf->{nicovideo}->{email},
    password => $conf->{nicovideo}->{password},
);
$nv->user_agent->cookie_jar($cookie_jar);

my @files = ();
my $sth = $dbh->prepare(
    'SELECT id, url FROM files WHERE filename IS NULL'
);
$sth->execute;
while(my $row = $sth->fetchrow_hashref)
{
    push(@files, $row);
}
$sth->finish; undef $sth;

$sth = $dbh->prepare(
    'UPDATE files SET title = ?, filename = ? WHERE id = ?'
);
foreach my $f (@files)
{
    if($f->{url} =~ m{^http://www\.nicovideo\.jp/watch/(\w{2}\d+)$})
    {
        my $res = &fetch_nicovideo($1);
        print Dump($res);
        if(defined($res))
        {
            if($res->{status} eq 'ok')
            {
                if($res->{embeddable} == 1)
                {
                    $sth->execute(
                        $res->{title},
                        $res->{filename},
                        $f->{id},
                    );
                    sleep 5
                }
            }
        }
    }
}
$sth->finish; undef $sth;

#my $sth = $dbh->prepare(
#    'INSERT OR IGNORE INTO replies ' .
#    '(status_id, text, user_id, user_name, user_screen_name, created_at) ' .
#    'VALUES (?, ?, ?, ?, ?, ?)'
#);
#$dbh->begin_work;
#foreach my $r (@{$replies})
#{
#    $sth->execute(
#        $r->{id},
#        $r->{text},
#        $r->{user}->{id},
#        $r->{user}->{name},
#        $r->{user}->{screen_name},
#        $r->{created_at},
#    );
#}
#$sth->finish; undef $sth;
#$dbh->commit;

sub fetch_nicovideo
{
    my $video_id = shift || return undef;

    printf "[%s]\n", $video_id;

    my $res = $nv->user_agent->get(
        'http://www.nicovideo.jp/api/getthumbinfo/' . $video_id
    );
    if(!$res->is_success)
    {
        warn "get api failed";
        return undef;
    }

    my $xs = XML::Simple->new;
    my $x = $xs->XMLin($res->decoded_content);
    if($x->{status} ne 'ok')
    {
        return { status => $x->{status} };
    }

    if($x->{thumb}->{embeddable} == 0)
    {
        return {
            status => $x->{status},
            embeddable => $x->{thumb}->{embeddable},
            title => $x->{thumb}->{title},
        };
    }

    #print Dump($x);

    printf "checking tags ...\n";
    my $tag_found = 0;
    my $tags;
    if(ref($x->{thumb}->{tags}) eq 'ARRAY')
    {
        foreach my $d (@{$x->{thumb}->{tags}})
        {
            printf "  domain: %s\n", $d->{domain};
            if($d->{domain} eq 'jp')
            {
                $tags = $d->{tag};
                last;
            }
        }
    }
    else
    {
        $tags = $x->{thumb}->{tags}->{tag};
    }
    foreach my $tag (@{$tags})
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
        if($t =~ /オリジナル曲$/)
        {
            $tag_found = 1;
        }
    }

    if($tag_found == 0)
    {
        warn "original tag not found";
        return undef;
    }

    my $file_source = 'files/song-sources/' . $video_id;
    if(!-f $file_source)
    {
        $nv->download($video_id, $file_source);
    }
    if(!-f $file_source || -z $file_source)
    {
        return undef;
    }

#    run ["ffmpeg", "-i", "$file_source", "-vn", "-f", "wav", "-"], "|",
#        ["grep", "-E", "(perl|PID)"], "|", ["grep", "-v", "grep"], ">", \&capture_out, timeout(5) or die "pipe command: $?";

    my $filename_song = $video_id . '.ogg';
    my $file_song = 'files/songs/' . $filename_song;
    my $title = sprintf "%s (%s)", $x->{thumb}->{title}, $video_id;
    if($video_id =~ /^nm/)
    {
        `$Bin/cws2fws.pl < $file_source | ffmpeg -i - -vn -f wav - | oggenc -t "$title" -q 6 -o $file_song -`;
    }
    else
    {
        `ffmpeg -i $file_source -vn -f wav - | oggenc -t "$title" -q 6 -o $file_song -`;
    }
    if(!-f $file_song)
    {
        return undef;
    }

    return {
        status => $x->{status},
        embeddable => $x->{thumb}->{embeddable},
        title => $x->{thumb}->{title},
        filename => $filename_song,
    };
}

sub load_config
{
    my $conffile = shift || $Bin . '/../conf/vcfm.conf';

    open FH, '<:encoding(utf8)', $conffile or return undef;
    my $yaml = join('', <FH>);
    close FH;

    my $conf = YAML::Load($yaml) or return undef;
    return $conf;
}

