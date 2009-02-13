#!/usr/bin/perl
use strict;
use warnings;
use utf8;

use FindBin qw($Bin);
use FindBin::libs;

use DBD::SQLite;
use Audio::MPD;
use Net::Twitter;
use YAML;
use Encode;

use VocaloidFM;

binmode STDOUT, ':encoding(utf8)';

my $conf = load_config;

my $dbh = DBI->connect(
    'dbi:SQLite:dbname=' . $conf->{db},
    '', '', {unicode => 1}
);

my $mpd = Audio::MPD->new(
    hostname => $conf->{mpd}->{host},
    port => $conf->{mpd}->{port},
);

&mpd_set_outputs(1);
$mpd->fade(2);
$mpd->repeat(1);
$mpd->random(0);
$mpd->volume(100);

my $twit = Net::Twitter->new(
    username => $conf->{twitter}->{username},
    password => $conf->{twitter}->{password},
);

my $current_id = -1;
if(defined(my $song = $mpd->song))
{
    $current_id = $song->id;
}

my $mainloop = 1;

$SIG{HUP} = \&stop;
$SIG{KILL} = \&stop;
$SIG{TERM} = \&stop;
$SIG{INT} = \&stop;

my $add_interval = 60;

my $next_addtime = 0; #time + $add_interval;

while($mainloop)
{
    if(time >= $next_addtime)
    {
        &add_playlist;
        $next_addtime = time + $add_interval;
    }

    if(!defined($mpd->song))
    {
        printf "Not playing, trying to restart\n";
        &mpd_set_outputs(0);
        sleep 1;
        &mpd_set_outputs(1);
        sleep 1;
        $mpd->play;
    }

    sleep 15;

    my $song = $mpd->song;
    next if(!defined($song));

    if($song->id != $current_id)
    {
        $current_id = $song->id;

        my $r = $dbh->selectrow_hashref(
            'SELECT url, title, username FROM files WHERE filename = ? LIMIT 1',
            undef, $song->file
        );

        my $min = int($song->time / 60);
        my $sec = $song->time - $min * 60;

        my $post = $r->{title};
        if(defined($r->{username}))
        {
            $post .= " / " . $r->{username};
        }
        $post = sprintf "\x{266b} %s (%d:%02d) %s",
            $post, $min, $sec, $r->{url};

        printf "%s\nNow Playing: %s\n", '-' x 78, $post;
        if($conf->{twitter}->{post_enable} == 1)
        {
            $twit->update(encode('utf8', $post));
        }
    }
}

exit;

sub add_playlist
{
    # ファイルが既に存在し、プレイリストに追加済みでないものを選択
    # TODO 初回は added = 1 のものも追加する？
    my $sth = $dbh->prepare(
        'SELECT programs.id as id, file_id, type, added, ' .
        '       url, title, filename ' .
        'FROM programs ' .
        'LEFT JOIN files ON programs.file_id = files.id ' .
        'WHERE files.filename IS NOT NULL AND programs.added = 0 ' .
        'ORDER BY id DESC'
    );
    $sth->execute;

    my @progs = ();
    while(my $row = $sth->fetchrow_hashref)
    {
        push(@progs, $row);
    }
    $sth->finish; undef $sth;

    return if($#progs < 0);

    printf "updating MPD database ...\n";
    my $update_time = 0;
    $mpd->updatedb;
    while(defined($mpd->status->updating_db))
    {
        sleep 1;
        last if($update_time++ >= 30);
    }

    printf "add to MPD playlist ...\n";
    foreach my $p (@progs)
    {
        #print Dump($p);
        printf " [%d] %s %s\n", $p->{id}, $p->{filename}, $p->{title};

        if($p->{type} == 1)
        {
            # request mode
            my @items = $mpd->playlist->as_items;
            my $pls_length = $#items + 1;
            my $current_pos = 0;
            if(defined(my $song = $mpd->song))
            {
                $current_pos = $song->pos;
            }

            #printf " MPD playing: [%d/%d]\n", $current_pos+1, $pls_length;

            # 追加して現在再生中の曲の次へ移動
            eval {
                $mpd->playlist->add($p->{filename});
                if($pls_length > 0)
                {
                    printf " move from %d to %d\n",
                        $pls_length, $current_pos+1;
                    $mpd->playlist->move($pls_length, $current_pos+1);
                }
            };
            if($@)
            {
                printf "ERROR while adding: %s\n", $@;
                next;
            }

            # TODO リクエストで追加した曲の削除は？
        }
        else
        {
            # normal mode
            eval {
                $mpd->playlist->add($p->{filename});
            };
            if($@)
            {
                printf "ERROR while adding: %s\n", $@;
                next;
            }
        }

        $dbh->begin_work;
        $dbh->do(
            'UPDATE programs SET added = 1 WHERE id = ?',
            undef, $p->{id},
        );
        $dbh->commit;
    }
}

sub stop
{
    $mainloop = 0;
}

sub mpd_set_outputs
{
    my $enable = shift || return undef;

    foreach(@{$conf->{mpd}->{outputs}})
    {
        if($enable == 1)
        {
            $mpd->output_enable($_);
        }
        else
        {
            $mpd->output_disable($_);
        }
    }
}

