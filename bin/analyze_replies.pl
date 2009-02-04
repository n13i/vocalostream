#!/usr/bin/perl
use strict;
use warnings;
use utf8;

use FindBin qw($Bin);
use Net::Twitter;
use YAML;
use DBD::SQLite;

binmode STDOUT, ':encoding(utf8)';

my $conf = &load_config;

my $dbh = DBI->connect(
    'dbi:SQLite:dbname=' . $Bin . '/../' . $conf->{db},
    '', '', {unicode => 1}
);

$dbh->begin_work;

my @updates = ();
my $sth = $dbh->prepare(
    'SELECT id, text FROM replies WHERE state = 0'
);
$sth->execute;
while(my $row = $sth->fetchrow_hashref)
{
    push(@updates, {
        id => $row->{id},
        text => $row->{text},
        url => undef,
        state => 0,
    });
}
$sth->finish; undef $sth;

foreach(@updates)
{
    printf "%s\n", $_->{text};

    if($_->{text} =~ m{((?:sm|nm)\d+)})
    {
        $_->{url} = 'http://www.nicovideo.jp/watch/' . $1;
        $_->{state} = 1;
        printf "  got video: %s\n", $_->{url};
    }    
    else
    {
        $_->{state} = -1;
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

    $dbh->do(
        'INSERT OR IGNORE INTO files (url) VALUES (?)',
        undef, $_->{url}
    );

    $dbh->do(
        'INSERT INTO programs (file_id, type) ' .
        'VALUES ((SELECT id FROM files WHERE url = ?), ?)',
        undef, $_->{url}, 1
    );
}

$dbh->commit;


sub load_config
{
    my $conffile = shift || $Bin . '/../conf/vcfm.conf';

    open FH, '<:encoding(utf8)', $conffile or return undef;
    my $yaml = join('', <FH>);
    close FH;

    my $conf = YAML::Load($yaml) or return undef;
    return $conf;
}

