#!/usr/bin/perl
use strict;
use warnings;
use utf8;

use FindBin qw($Bin);
use FindBin::libs;

use YAML;
use DBD::SQLite;

use VocaloidFM;

binmode STDOUT, ':encoding(utf8)';

my $conf = load_config;

my $dbh = DBI->connect(
    'dbi:SQLite:dbname=' . $conf->{db},
    '', '', {sqlite_unicode => 1}
);

my $type = shift @ARGV || 0;
my $url  = shift @ARGV || '';

&usage if($type !~ /^\d+$/);
&usage if($url !~ m{^http://www\.nicovideo\.jp/watch/\w{2}\d+$});

#printf "%d %s\n", $type, $url;

my $r1 = $dbh->do(
    'INSERT OR IGNORE INTO files (url) VALUES (?)',
    undef, $url
);
#printf "add file: %s\n", ($r == 1 ? 'ok' : 'ignored (maybe already exists)');

my $r2 = $dbh->do(
    'INSERT INTO programs (file_id, type) ' .
    'VALUES ((SELECT id FROM files WHERE url = ?), ?)',
    undef, $url, $type
);
#printf "add program: %s\n", ($r == 1 ? 'ok' : 'failed');

printf "[%s] %d: %s\n",
    ($r2 == 1 ? ($r1 == 1 ? 'O' : 'E') : 'X'),
    $type,
    $url;

exit;


sub usage
{
    printf STDERR "usage: add_program.pl [type] [url]\n";
    exit 1;
}

