#!/usr/bin/perl
use strict;
use warnings;
use utf8;

use FindBin qw($Bin);
use FindBin::libs;

use Net::Twitter;
use YAML;
use DBD::SQLite;
use Encode;

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

printf "%s/%s\n", $conf->{dirs}->{songs}, $program->{filename};

binmode STDERR, ':encoding(utf8)';
printf STDERR "%s\n", "-" x 78;
printf STDERR "Now playing: [%d] %s\n", $program->{id}, $program->{title};
printf STDERR "%s\n", "-" x 78;

exit if($program->{filename} =~ /^intermission/);

if($conf->{twitter}->{post_enable} == 1)
{
    my $post = sprintf "\x{266b} %s %s",
        $program->{title}, $program->{url};
    $twit->update(encode('utf8', $post));
}

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

    # デフォルトプレイリスト以外はランダム再生しない(順に消化)
    my $sql_order = 'ORDER BY programs.id';
    if($type == 0 && $conf->{playlist}->{random} == 1)
    {
        $sql_order = 'ORDER BY RANDOM()';
    }

    my $sth = $dbh->prepare(
        'SELECT programs.id as id, file_id, type, played, ' .
        '       url, title, filename ' .
        'FROM programs ' .
        'LEFT JOIN files ON programs.file_id = files.id ' .
        'WHERE files.filename IS NOT NULL AND programs.played = 0 ' .
        'AND type = ? ' .
        $sql_order . ' LIMIT 1'
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

