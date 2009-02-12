package VocaloidFM;

use strict;
use warnings;
use utf8;

use base qw(Exporter);
our @EXPORT = qw(load_config);

use FindBin qw($Bin);

sub load_config
{
    my $conffile = shift || $Bin . '/../conf/icesradio.conf';

    open FH, '<:encoding(utf8)', $conffile or return undef;
    my $yaml = join('', <FH>);
    close FH;

    my $conf = YAML::Load($yaml) or return undef;
    return $conf;
}

1;
__END__

