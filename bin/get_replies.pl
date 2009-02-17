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

my $twit = Net::Twitter->new(
    username => $conf->{twitter}->{username},
    password => $conf->{twitter}->{password},
);

my $recent = $dbh->selectrow_hashref(
    'SELECT status_id FROM replies ORDER BY status_id DESC LIMIT 1'
);

printf "==> replies since %d ", $recent->{status_id};
my @replies = ();
for(my $i = 0; $i < 3; $i++)
{
    printf ".";
    my $r = $twit->replies({page => $i+1, since_id => $recent->{status_id}});
    last if($#{$r} < 0);
    push(@replies, @{$r});
}
printf "\n";

my $sth = $dbh->prepare(
    'INSERT OR IGNORE INTO replies ' .
    '(status_id, text, user_id, user_name, user_screen_name, created_at) ' .
    'VALUES (?, ?, ?, ?, ?, ?)'
);
$dbh->begin_work;
foreach my $r (sort { $b->{id} <=> $a->{id} } @replies)
{
    printf "[%d] %s: %s\n",
        $r->{id}, $r->{user}->{screen_name}, $r->{text};

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

