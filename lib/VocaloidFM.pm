package VocaloidFM;

use strict;
use warnings;
use utf8;

use base qw(Exporter);
our @EXPORT = qw(load_config get_config);

use FindBin qw($Bin);
use YAML;

my $instance;

BEGIN {
    $instance = bless {
        config => undef,
    }, __PACKAGE__;
}

# static
sub get_config
{
    return $instance->{config};
}

# static
sub load_config
{
    my $conffile = shift || $Bin . '/../conf/icesradio.conf';

    open FH, '<:encoding(utf8)', $conffile or return undef;
    my $yaml = join('', <FH>);
    close FH;

    my $conf = YAML::Load($yaml) or return undef;

    $instance->{config} = $conf;

    return $conf;
}

1;
__END__

