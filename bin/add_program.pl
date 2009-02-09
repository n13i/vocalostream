#!/usr/bin/perl
use strict;
use warnings;
use utf8;

use FindBin qw($Bin);
use YAML;
use DBD::SQLite;

binmode STDOUT, ':encoding(utf8)';

my $conf = &load_config;

my $dbh = DBI->connect(
    'dbi:SQLite:dbname=' . $conf->{db},
    '', '', {unicode => 1}
);

my $type = shift @ARGV || 0;
my $url  = shift @ARGV || '';

&usage if($type !~ /^\d+$/);
&usage if($url !~ m{^http://www\.nicovideo\.jp/watch/\w{2}\d+$});

printf "%d %s\n", $type, $url;

my $r = $dbh->do(
    'INSERT OR IGNORE INTO files (url) VALUES (?)',
    undef, $url
);
printf "add file: %s\n", ($r == 1 ? 'ok' : 'ignored (maybe already exists)');

$r = $dbh->do(
    'INSERT INTO programs (file_id, type) ' .
    'VALUES ((SELECT id FROM files WHERE url = ?), ?)',
    undef, $url, $type
);
printf "add program: %s\n", ($r == 1 ? 'ok' : 'failed');

exit;


sub usage
{
    printf STDERR "usage: add_program.pl [type] [url]\n";
    exit 1;
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

