#!/usr/bin/perl
use strict;
use warnings;
use utf8;

use FindBin qw($Bin);
use FindBin::libs;

use Net::Twitter;
use YAML;
use DBD::SQLite;

use VocaloidFM;

binmode STDOUT, ':encoding(utf8)';

my $conf = load_config;

my $dbh = DBI->connect(
    'dbi:SQLite:dbname=' . $conf->{db},
    '', '', {unicode => 1}
);

$dbh->begin_work;

my @updates = ();
my $sth = $dbh->prepare(
    'SELECT id, user_screen_name, text FROM replies WHERE state = 0 ' .
    'ORDER BY status_id ASC'
);
$sth->execute;
while(my $row = $sth->fetchrow_hashref)
{
    push(@updates, {
        id => $row->{id},
        name => $row->{user_screen_name},
        text => $row->{text},
        urls => [],
        state => 0,
    });
}
$sth->finish; undef $sth;

my @files = ();
foreach my $s (@updates)
{
    logger "%s: %s\n", $s->{name}, $s->{text};

    # 動画 ID を取り出す
    my @urls = $s->{text} =~ m{((?:sm|nm)\d+)}sg;
    if($#urls >= 0)
    {
        $s->{state} = 1;

        # 複数同時リクエスト時にはユニークにする
        my %tmp;
        foreach(grep(!$tmp{$_}++, @urls))
        {
            my $url = 'http://www.nicovideo.jp/watch/' . $_;
            logger "  got video: %s\n", $url;
            push(@{$s->{urls}}, $url);
        }    
    }
    else
    {
        $s->{state} = -1;
    }
}

$sth = $dbh->prepare(
    'UPDATE replies SET state = ? WHERE id = ?'
);
foreach(@updates)
{
    $sth->execute($_->{state}, $_->{id});
}
$sth->finish; undef $sth;

foreach(@updates)
{
    next if($_->{state} != 1);

    foreach my $url (@{$_->{urls}})
    {
        $dbh->do(
            'INSERT OR IGNORE INTO files (url) VALUES (?)',
            undef, $url
        );
        $dbh->do(
            'INSERT INTO programs (file_id, type, request_id) ' .
            'VALUES ((SELECT id FROM files WHERE url = ?), ?, ?)',
            undef, $url, 1, $_->{id}
        );
    }
}

$dbh->commit;

