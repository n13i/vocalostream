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

# リクエストをチェック
sub get_request
{
    my $program = undef;

    my $sth = $dbh->prepare(
        'SELECT * FROM requests LEFT JOIN files ' .
        'ON requests.file_id = files.id ' .
        'WHERE files.filename IS NOT NULL AND requests.played = 0 ' .
        'ORDER BY requests.id LIMIT 1'
    );
    $sth->execute;
    my $row = $sth->fetchrow_hashref;
    $sth->finish; undef $sth;

    if(defined($row))
    {
        $dbh->do(
            'UPDATE requests SET played = 1 WHERE id = ?',
            undef, $row->{id},
        );

        $program = {
            type => 'request',
            data => $row,
        };
    }

    return $program;
}

# 通常プログラム
sub get_program
{
    my $program = undef;

    # 全部再生済みなら再生済みフラグを 0 に戻す
    $dbh->do(
        'UPDATE programs SET played = 0 WHERE played = (' .
        '  CASE (SELECT COUNT(*) FROM programs ' .
        '        LEFT JOIN files ON programs.file_id = files.id ' .
        '        WHERE files.filename IS NOT NULL AND programs.played = 0) ' .
        '    WHEN 0 THEN 1 ' .
        '    ELSE 0 ' .
        '  END ' .
        ')'
    );
    my $sth = $dbh->prepare(
        'SELECT * FROM programs LEFT JOIN files ' .
        'ON programs.file_id = files.id ' .
        'WHERE files.filename IS NOT NULL AND programs.played = 0 ' .
        'ORDER BY programs.id LIMIT 1'
    );
    $sth->execute;
    my $row = $sth->fetchrow_hashref;
    $sth->finish; undef $sth;

    if(defined($row))
    {
        $dbh->do(
            'UPDATE programs SET played = 1 WHERE id = ?',
            undef, $row->{id},
        );

        $program = {
            type => 'program',
            data => $row,
        };
    }

    return $program;
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

