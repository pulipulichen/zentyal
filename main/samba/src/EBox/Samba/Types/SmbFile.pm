# Copyright (C) 2013 Zentyal S.L.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License, version 2, as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

use strict;
use warnings;

# Class: EBox::Samba::Types::SmbFile

package EBox::Samba::Types::SmbFile;

use base 'EBox::Types::File';

use EBox::Exceptions::Internal;
use EBox::Exceptions::NotImplemented;

sub _moveToPath
{
    my ($self) = @_;

    my $path = $self->path();
    my $tmpPath = $self->tmpPath();
    if (not -f $tmpPath) {
        throw EBox::Exceptions::Internal(
            "No file found at $tmpPath for moving to $path");
    }

    my $user = $self->user();
    my $group = $self->group();
    unless (($user eq 'ebox') and ($group eq 'ebox')) {
         throw EBox::Exceptions::NotImplemented(
             "user and group combination ($user:$group) not supported");
    }

    my $smb = new EBox::Samba::SmbClient(RID => 500);
    $smb->copy_file_to_smb($tmpPath, $path);
}

1;
