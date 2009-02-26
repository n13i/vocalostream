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
    'UPDATE files SET title = ?, filename = ?, username = ?, pname = ?, ' .
    "last_checked = strftime('%s', 'now'), " .
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
        if(defined($res))
        {
            #print Dump($res);
            if($res->{result}->{code} > 0)
            {
                $result = 1;
                if($res->{downloaded} == 1) { sleep 5; }
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
                $res->{pname},
                $f->{id},
            );
        }
        else
        {
            $sth->execute(
                undef,
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

    my $status = $dl->check_status($video_id);
    if(!defined($status))
    {
        printf "ERROR: status check failed\n";
        return undef;
    }

    printf "%s\n", $status->{thumbinfo}->{thumb}->{title};

    if($status->{code} < 0)
    {
        printf "ERROR: %s is rejected by status check: %s\n",
            $video_id, $status->{text}; 
        return {
            result => $status,
        };
    }

    printf "%s is accepted by status check\n", $video_id; 

    my $x = $status->{thumbinfo};

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
            return {
                result => { code => -6, text => $@ },
            };
        }
        printf "done, takes %d seconds\n", (time - $start_time);
        rename $file_source . '.tmp', $file_source;
        $downloaded = 1;
    }
    if(!-f $file_source || -z $file_source)
    {
        printf "ERROR: missing source file\n";
        return {
            result => { code => -6, text => 'missing source file' },
        };
    }


    my $filename_song = $video_id . '.ogg';
    my $file_song = sprintf "%s/%s", $conf->{dirs}->{songs}, $filename_song;
    my $title = sprintf "%s (from http://www.nicovideo.jp/watch/%s)", $x->{thumb}->{title}, $video_id;

    # 投稿者名取得
    my $username = $dl->get_username($video_id);
    my $artist = '';
    my $pname = undef;
    if(defined($username))
    {
        $artist = $username;
        printf "got username: %s\n", $username;

        $pname = $dl->get_pname($username, $status->{tags});
        if(defined($pname))
        {
            printf "got pname: %s\n", $pname;
            $artist .= ' (' . $pname . ')';
        }
    }

    my $cmd_file = $conf->{cmds}->{file};
    my $mimetype = `$cmd_file -b -i $file_source`;
    chomp $mimetype;
    printf "mime type: %s\n", $mimetype;

    printf "converting %s ...\n", $title;
    my ($out, $err);
    if($mimetype =~ /flash/)
    {
        # 展開してから ffmpeg へ
        # 途中までしか変換されないことがあったので
        # パイプではなくファイルにして渡す
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
             '-a', $artist,
             '-q', $conf->{converter}->{quality},
             '-o', $file_song, '-'],
            \$out, \$err, timeout($conf->{converter}->{timeout}) or die "$?";
        eval { unlink($tmpswf); };
    }
    elsif($mimetype =~ /mp4/)
    {
        # HE-AAC のデコードミスを防ぐため
        # 一度抽出して faad でデコード
        my $tmpaac = $file_source . '.tmp.aac';
        run [$conf->{cmds}->{ffmpeg},
             '-y',
             '-i', $file_source,
             '-vn',
             '-acodec', 'copy',
             $tmpaac],
            \$out, \$err, timeout($conf->{converter}->{timeout}) or die "$?";
        run [$conf->{cmds}->{faad}, '-q', '-o', '-', $tmpaac], '|',
            [$conf->{cmds}->{oggenc},
             '-Q',
             '-t', $title,
             '-a', $artist,
             '-q', $conf->{converter}->{quality},
             '-o', $file_song, '-'],
            \$out, \$err, timeout($conf->{converter}->{timeout}) or die "$?";
        eval { unlink($tmpaac); };
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
             '-a', $artist,
             '-q', $conf->{converter}->{quality},
             '-o', $file_song, '-'],
            \$out, \$err, timeout($conf->{converter}->{timeout}) or die "$?";
    }
    print $err;
    if(!-f $file_song)
    {
        printf "ERROR: failed to convert\n";
        return {
            result => { code => -7, text => 'failed to convert' },
        };
    }

    printf "running VorbisGain ...\n";
    # set VorbisGain tags
    run [$conf->{cmds}->{vorbisgain}, '-q', $file_song],
        \$out, \$err, timeout($conf->{converter}->{vorbisgain_timeout}) or die "$?";

    printf "done.\n";

    return {
        result => { code => 1, text => 'success' },
        title => $x->{thumb}->{title},
        filename => $filename_song,
        downloaded => $downloaded,
        username => $username,
        pname => $pname,
    };
}

