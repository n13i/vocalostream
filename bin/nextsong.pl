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

my $sth;
my $program = undef;

$program = &get_program(1);
if(!defined($program))
{
    warn "no requests";
    $program = &get_program;
}

if(!defined($program))
{
    warn "there's no program";
    exit 1;
}

printf "%s/%s\n", '/home/naoh/Works/vocaloid.fm/files/songs',
    $program->{filename};

binmode STDERR, ':encoding(utf8)';
printf STDERR "Now playing: [%d] %s\n", $program->{id}, $program->{title};

exit;



sub get_program
{
    my $type = shift || 0;
    my $program = undef;

    # 全部再生済みならデフォルトプレイリストの再生済みフラグを 0 に戻す
    $dbh->do(
        'UPDATE programs SET played = 0 WHERE played = (' .
        '  CASE (SELECT COUNT(*) FROM programs ' .
        '        LEFT JOIN files ON programs.file_id = files.id ' .
        '        WHERE files.filename IS NOT NULL AND programs.played = 0) ' .
        '    WHEN 0 THEN 1 ' .
        '    ELSE 0 ' .
        '  END ' .
        ') AND type = 0'
    );
    my $sth = $dbh->prepare(
        'SELECT programs.id as id, file_id, type, played, ' .
        '       url, title, filename ' .
        'FROM programs ' .
        'LEFT JOIN files ON programs.file_id = files.id ' .
        'WHERE files.filename IS NOT NULL AND programs.played = 0 ' .
        'AND type = ? ' .
        'ORDER BY programs.id LIMIT 1'
    );
    $sth->execute($type);
    my $row = $sth->fetchrow_hashref;
    $sth->finish; undef $sth;

    if(defined($row))
    {
        $dbh->do(
            'UPDATE programs SET played = 1 WHERE id = ?',
            undef, $row->{id},
        );

        $program = $row;
    }

    return $program;
}

sub load_config
{
    my $conffile = shift || $Bin . '/../conf/vcfm.conf';

    open FH, '<:encoding(utf8)', $conffile or return undef;
    my $yaml = join('', <FH>);
    close FH;

    my $conf = YAML::Load($yaml) or return undef;
    return $conf;
}

