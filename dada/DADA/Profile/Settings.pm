package DADA::Profile::Settings; 
use strict;
use lib qw(./ ../ ../../ ../../DADA ../perllib); 


my $t = 0; 

use Carp qw(croak carp); 

my $type; 
my $backend; 
use DADA::Config qw(!:DEFAULT); 	
use DADA::App::Guts; 

BEGIN {
    $type = $DADA::Config::SETTINGS_DB_TYPE;
    if ( $type =~ m/sql/i ) {
        $type = 'baseSQL';
    }
    else {
        $type = 'Db';
    }
}
use base "DADA::Profile::Settings::$type";


sub new {

    my $class = shift;
    my ($args) = @_;

    my $self = {};
    bless $self, $class;
    $self->_init($args);
    return $self;
}


=pod

=head1 COPYRIGHT 

Copyright (c) 1999 - 2016 Justin Simoni All rights reserved. 

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place - Suite 330, 
Boston, MA  02111-1307, USA.

=cut 



1;
