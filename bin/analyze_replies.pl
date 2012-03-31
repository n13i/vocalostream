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

my $logdomain = 'ReplyAnalyzer';

my $conf = load_config;

my $dbh = DBI->connect(
    'dbi:SQLite:dbname=' . $conf->{db},
    '', '', {sqlite_unicode => 1}
);


$dbh->begin_work;

my @updates = ();
my $sth = $dbh->prepare(
    'SELECT id, user_screen_name, text FROM replies WHERE state = 0 ' .
    'ORDER BY status_id ASC'
);
$sth->execute;
while(my $row = $sth->fetchrow_hashref)
{
    push(@updates, {
        id => $row->{id},
        name => $row->{user_screen_name},
        text => $row->{text},
        urls => [],
        state => 0,
    });
}
$sth->finish; undef $sth;

my @files = ();
foreach my $s (@updates)
{
    logger $logdomain, "%s: %s\n", $s->{name}, $s->{text};

    if($s->{text} !~ /^\s*\@vocaloid_fm\s/)
    {
        $s->{state} = -1;
        next;
    }

    # 動画 ID を取り出す
    my @urls = $s->{text} =~ m{((?:sm|nm)\d+)}sg;
    if($#urls < 0)
    {
        # テキスト検索を試す
        my $text = $s->{text};
        $text =~ s/^\s*\@vocaloid_fm\s//;

        logger $logdomain, "trying word search [%s]\n", $text;
        my $url = &word_search($text);

        if(defined($url))
        {
            push(@urls, $url);
        }
    }

    if($#urls >= 0)
    {
        $s->{state} = 1;

        # 複数同時リクエスト時にはユニークにする
        my %tmp;
        foreach(grep(!$tmp{$_}++, @urls))
        {
            my $url = $_;
            if($url !~ /^http/)
            {
                $url = 'http://www.nicovideo.jp/watch/' . $url;
            }
            logger $logdomain, "  got video: %s\n", $url;
            push(@{$s->{urls}}, $url);
        }
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

    foreach my $url (@{$_->{urls}})
    {
        $dbh->do(
            'INSERT OR IGNORE INTO files (url) VALUES (?)',
            undef, $url
        );
        $dbh->do(
            'INSERT INTO programs (file_id, type, request_id) ' .
            'VALUES ((SELECT id FROM files WHERE url = ?), ?, ?)',
            undef, $url, 1, $_->{id}
        );
    }
}

$dbh->commit;


sub word_search
{
    my $q = shift;
    my $query_substr_len = 2;
    
    logger $logdomain, "search query = %s\n", $q;

    my $rc = $dbh->do(
        'CREATE TEMPORARY TABLE temp_search (' .
        '  id      INTEGER PRIMARY KEY,' .
        '  file_id INTEGER NOT NULL REFERENCES files(id),' .
        '  matches INTEGER NOT NULL DEFAULT 1,' .
        '  UNIQUE(file_id)' .
        ')'
    );
    die if(!defined($rc));
    
    my $sth_update = $dbh->prepare(
        'UPDATE OR IGNORE temp_search SET matches = (matches + 1) ' .
        'WHERE file_id IN (' .
        '  SELECT id FROM files WHERE title LIKE ? OR username LIKE ?' .
        ')'
    );
    my $sth_insert = $dbh->prepare(
        'INSERT OR IGNORE INTO temp_search (file_id) ' .
        '  SELECT id FROM files WHERE title LIKE ? OR username LIKE ?'
    );

    my @queries = split(/\s+/, $q);
    foreach my $query (@queries)
    {
        if(length($query) > $query_substr_len)
        {
            for(my $i = 0; $i <= length($query)-$query_substr_len; $i++)
            {
                my $surface = substr($query, $i, $query_substr_len);
                $surface =~ s/(^\s+|\s+$)//;
                logger $logdomain, "[%s]\n",  $surface;
                my $q = '%' . $surface . '%';
                $sth_update->execute($q, $q);
                if($sth_update->rows <= 0)
                {
                    $sth_insert->execute($q, $q);
                }
            }
        }
        else
        {
            my $q = '%' . $query . '%';
            $sth_update->execute($q, $q);
            if($sth_update->rows <= 0)
            {
                $sth_insert->execute($q, $q);
            }
        }
    }
    undef $sth_update;
    undef $sth_insert;
    
    # debug
    #my $match = $dbh->selectrow_hashref(
    #    'SELECT COUNT(id) AS count FROM temp_search');
    #printf "Matches: %d\n", $match->{count};
    
    my $row = $dbh->selectrow_hashref(
        'SELECT file_id, matches, title, url ' .
        'FROM temp_search ' .
        'LEFT JOIN files ON temp_search.file_id = files.id ' .
        'WHERE state = 1 ' .
        'ORDER BY matches DESC, file_id ASC ' .
        'LIMIT 1'
    );
    print Dump($row);
    my $url = undef;
    if(defined($row))
    {
        $url = $row->{url};
        logger $logdomain, "[%d] [%s] %s [M:%d]\n",
            $row->{file_id}, $row->{title}, $row->{url}, $row->{matches};
    }

    $dbh->do('DROP TEMPORARY TABLE temp_search');

    return $url;
}

