#!/usr/bin/perl
use strict;
use warnings;
use utf8;

use FindBin qw($Bin);
use YAML;
use DBD::SQLite;
use Encode;
use Audio::MPD;

binmode STDOUT, ':encoding(utf8)';

my $conf = &load_config;

my $dbh = DBI->connect(
    'dbi:SQLite:dbname=' . $conf->{db},
    '', '', {unicode => 1}
);

my $mpd = Audio::MPD->new(
    hostname => $conf->{mpd}->{host},
    port => $conf->{mpd}->{port},
);

# ファイルが既に存在し、プレイリストに追加済みでないものを選択
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

exit if($#progs < 0);

printf "updating MPD database ...\n";
my $update_time = 0;
$mpd->updatedb;
while(defined($mpd->status->updating_db))
{
    sleep 1;
    last if($update_time++ >= 30);
}

foreach my $p (@progs)
{
    print Dump($p);

    if($p->{type} == 1)
    {
        # request mode
        my @items = $mpd->playlist->as_items;
        my $pls_length = $#items + 1;
        my $current_pos = $mpd->song->pos;

        printf "MPD playing: [%d/%d]\n", $current_pos+1, $pls_length;

        # 追加して現在再生中の曲の次へ移動
        eval {
            $mpd->playlist->add($p->{filename});
            $mpd->playlist->move($pls_length, $current_pos+1);
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

    $dbh->do(
        'UPDATE programs SET added = 1 WHERE id = ?',
        undef, $p->{id},
    );
}

exit;


sub load_config
{
    my $conffile = shift || $Bin . '/../conf/icesradio.conf';

    open FH, '<:encoding(utf8)', $conffile or return undef;
    my $yaml = join('', <FH>);
    close FH;

    my $conf = YAML::Load($yaml) or return undef;
    return $conf;
}

