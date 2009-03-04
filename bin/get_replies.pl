#!/usr/bin/perl
use strict;
use warnings;
use utf8;

use FindBin qw($Bin);
use FindBin::libs;

use Net::Twitter;
use YAML;
use DBD::SQLite;
use LWP::UserAgent;
use HTTP::Status;

use VocaloidFM;

binmode STDOUT, ':encoding(utf8)';

my $logdomain = 'ReplyFetcher';

my $conf = load_config;

my $dbh = DBI->connect(
    'dbi:SQLite:dbname=' . $conf->{db},
    '', '', {unicode => 1}
);
my $dbh_tinyurl = DBI->connect(
    'dbi:SQLite:dbname=' . $conf->{tinyurl}->{db},
    '', '', {unicode => 1}
);

my $twit = Net::Twitter->new(
    username => $conf->{twitter}->{username},
    password => $conf->{twitter}->{password},
);

my $recent = $dbh->selectrow_hashref(
    'SELECT status_id FROM replies ORDER BY status_id DESC LIMIT 1'
);

#printf "* getting replies since %d ", $recent->{status_id};
my @replies = ();
for(my $i = 0; $i < 3; $i++)
{
#    printf ".";
    my $r = $twit->replies({page => $i+1, since_id => $recent->{status_id}});

    last if(!defined($r));
    last if($#{$r} < 0);

    push(@replies, @{$r});

    last if($#{$r} < 19);
}
#printf " done\n";

my $sth = $dbh->prepare(
    'INSERT OR IGNORE INTO replies ' .
    '(status_id, text, user_id, user_name, user_screen_name, created_at) ' .
    'VALUES (?, ?, ?, ?, ?, ?)'
);
$dbh->begin_work;
foreach my $r (sort { $a->{id} <=> $b->{id} } @replies)
{
    my $tinyurl_expr = $conf->{tinyurl}->{expr};
    my @tinyurls = $r->{text} =~ m{($tinyurl_expr)}sg;
    foreach(@tinyurls)
    {
        my $expanded = &expand_tinyurl($_);                                             if(defined($expanded))
        {
            logger $logdomain, "  untinyurlize: %s\n", $expanded;
            $r->{text} =~ s#$_#$expanded#g;
        }
    }

    logger $logdomain, "%d %s: %s\n",
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

