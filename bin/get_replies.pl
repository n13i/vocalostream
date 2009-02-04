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

my $twit = Net::Twitter->new(
    username => $conf->{twitter}->{username},
    password => $conf->{twitter}->{password},
);

my $replies = $twit->replies;

my $sth = $dbh->prepare(
    'INSERT OR IGNORE INTO replies ' .
    '(status_id, text, user_id, user_name, user_screen_name, created_at) ' .
    'VALUES (?, ?, ?, ?, ?, ?)'
);
$dbh->begin_work;
foreach my $r (@{$replies})
{
    printf "%s: %s\n", $r->{user}->{screen_name}, $r->{text};

    $sth->execute(
        $r->{id},
        $r->{text},
        $r->{user}->{id},
        $r->{user}->{name},
        $r->{user}->{screen_name},
        $r->{created_at},
    );
}
$sth->finish; undef $sth;
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

