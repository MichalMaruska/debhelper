package Debian::Debhelper::Buildsystem::qmake_qt4;

use strict;
use warnings;
use parent qw(Debian::Debhelper::Buildsystem::qmake);

sub DESCRIPTION {
	"qmake for QT 4 (*.pro)";
}

sub configure {
	my $this=shift;
	$Debian::Debhelper::Buildsystem::qmake::qmake="qmake-qt4";
	$this->SUPER::configure(@_);
}

1
