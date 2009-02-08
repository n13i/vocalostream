#!/usr/bin/perl
use strict;
use warnings;
use utf8;

use FindBin qw($Bin);
use Net::Twitter;
use YAML;
use DBD::SQLite;
use LWP::UserAgent;
use HTTP::Status;

binmode STDOUT, ':encoding(utf8)';

my $conf = &load_config;

my $dbh = DBI->connect(
    'dbi:SQLite:dbname=' . $conf->{db},
    '', '', {unicode => 1}
);
my $dbh_tinyurl = DBI->connect(
    'dbi:SQLite:dbname=' . $conf->{tinyurl}->{db},
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

foreach my $s (@updates)
{
    printf "%s\n", $s->{text};

    my $tinyurl_expr = $conf->{tinyurl}->{expr};
    my @tinyurls = $s->{text} =~ m{($tinyurl_expr)}sg;
    foreach(@tinyurls)
    {
        print $_ . " -> ";
        my $expanded = &expand_tinyurl($_);                                             if(defined($expanded))
        {
            print $expanded;
            $s->{text} =~ s#$_#$expanded#g;
        }
        print "\n";
    }

    if($s->{text} =~ m{((?:sm|nm)\d+)})
    {
        $s->{url} = 'http://www.nicovideo.jp/watch/' . $1;
        $s->{state} = 1;
        printf "  got video: %s\n", $s->{url};
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
    my $conffile = shift || $Bin . '/../conf/icesradio.conf';

    open FH, '<:encoding(utf8)', $conffile or return undef;
    my $yaml = join('', <FH>);
    close FH;

    my $conf = YAML::Load($yaml) or return undef;
    return $conf;
}

sub expand_tinyurl
{
    my $tinyurl = shift || return undef;

    my $hashref = $dbh_tinyurl->selectrow_hashref(
        "SELECT url FROM tinyurl WHERE tiny = '" . $tinyurl . "' LIMIT 1"
    );
    if(defined($hashref->{url}))
    {
        return $hashref->{url};
    }

    my $ua = LWP::UserAgent->new();
    $ua->timeout(60);
    $ua->requests_redirectable([]);

    my $req = HTTP::Request->new(GET => $tinyurl);
    my $res = $ua->request($req);
    if(!is_redirect($res->code))
    {
        return undef;
    }

    my $sth = $dbh_tinyurl->prepare(
        'INSERT OR IGNORE INTO tinyurl (tiny, url) VALUES (?, ?)'
    );
    $sth->execute($tinyurl, $res->header('Location'));
    $sth->finish; undef $sth;

    return $res->header('Location');
}

