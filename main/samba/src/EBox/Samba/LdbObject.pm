# Copyright (C) 2012-2013 Zentyal S.L.
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

package EBox::Samba::LdbObject;

use EBox::Global;
use EBox::Gettext;

use EBox::Exceptions::Internal;
use EBox::Exceptions::External;
use EBox::Exceptions::MissingArgument;
use EBox::Exceptions::UnwillingToPerform;

use Data::Dumper;
use Net::LDAP::LDIF;
use Net::LDAP::Constant qw(LDAP_LOCAL_ERROR);
use Net::LDAP::Control;

use Perl6::Junction qw(any);
use Error qw(:try);

my $_sambaMod;

# Method: new
#
#   Instance an object readed from LDB.
#
# Parameters:
#
#      dn - Full dn for the entry
#  or
#      ldif - Net::LDAP::LDIF for the entry
#  or
#      entry - Net::LDAP entry
#
sub new
{
    my ($class, %params) = @_;

    my $self = {};
    if ($params{entry}) {
        $self->{entry} = $params{entry};
    } elsif ($params{ldif}) {
        my $ldif = Net::LDAP::LDIF->new($params{ldif}, "r");
        $self->{entry} = $ldif->read_entry();
    } elsif ($params{dn}) {
        $self->{dn} = $params{dn};
    }

    bless ($self, $class);
    return $self;
}

# Method: exists
#
#   Returns 1 if the object exist, 0 if not
#
sub exists
{
    my ($self) = @_;

    # User exists if we already have its entry
    return 1 if ($self->{entry});

    $self->{entry} = $self->_entry();

    return (defined $self->{entry});
}

# Method: get
#
#   Read an user attribute
#
# Parameters:
#
#   attribute - Attribute name to read
#
sub get
{
    my ($self, $attr) = @_;
    if (wantarray()) {
        my @value = $self->_entry->get_value($attr);
        foreach my $el (@value) {
            utf8::decode($el);
        }
        return @value;
    } else {
        my $value = $self->_entry->get_value($attr);
        utf8::decode($value);
        return $value;
    }
}

# Method: set
#
#   Set an user attribute.
#
# Parameters:
#
#   attribute - Attribute name to read
#   value     - Value to set (scalar or array ref)
#   lazy      - Do not update the entry in LDAP
#
sub set
{
    my ($self, $attr, $value, $lazy) = @_;

    $self->_entry->replace($attr => $value);
    $self->save() unless $lazy;
}

# Method: add
#
#   Adds a value to an attribute without removing previous ones (if any)
#
# Parameters:
#
#   attribute - Attribute name to read
#   value     - Value to set (scalar or array ref)
#   lazy      - Do not update the entry in LDAP
#
sub add
{
    my ($self, $attr, $value, $lazy) = @_;

    $self->_entry->add($attr => $value);
    $self->save() unless $lazy;
}

# Method: delete
#
#   Delete all values from an attribute
#
#   Parameters (for attribute deletion):
#
#       attribute - Attribute name to remove
#       lazy      - Do not update the entry in LDAP
#
sub delete
{
    my ($self, $attr, $lazy) = @_;
    $self->deleteValues($attr, [], $lazy);
}

# Method: deleteValues
#
#   Deletes values from an object if they exists
#
#   Parameters (for attribute deletion):
#
#       attribute - Attribute name to read
#       values    - reference to the list of values to delete.
#                   Empty list means all attributes
#       lazy      - Do not update the entry in LDAP
#
sub deleteValues
{
    my ($self, $attr, $values, $lazy) = @_;

    if (grep (/$attr/i, $self->_entry->attributes())) {
        $self->_entry->delete($attr, $values);
        $self->save() unless $lazy;
    }
}

# Method: checkObjectErasability
#
#   Returns whether the object could be deleted or not.
sub checkObjectErasability
{
    my ($self) = @_;

    # Refuse to delete critical system objects
    my $isCritical = $self->get('isCriticalSystemObject');
    return not ($isCritical and (lc ($isCritical) eq 'true'));

}

# Method: deleteObject
#
#   Deletes this object from the LDAP
#
sub deleteObject
{
    my ($self) = @_;

    unless ($self->checkObjectErasability()) {
        throw EBox::Exceptions::UnwillingToPerform(
            reason => __x('The object {x} is a system critical object.',
                          x => $self->dn()));
    }

    $self->_entry->delete();
    $self->save();
}

# Method: remove
#
#   Remove a value from the given attribute, or the whole
#   attribute if no values left
#
#   If an array ref is received as value, all the values will be
#   deleted at the same time
#
# Parameters:
#
#   attribute - Attribute name
#   value(s)  - Value(s) to remove (value or array ref to values)
#   lazy      - Do not update the entry in LDAP
#
sub remove
{
    my ($self, $attr, $value, $lazy) = @_;

    # Delete attribute only if it exists
    if ($attr eq any $self->_entry->attributes) {
        if (ref ($value) ne 'ARRAY') {
            $value = [ $value ];
        }

        $self->_entry->delete($attr, $value);
        $self->save() unless $lazy;
    }
}

# Method: save
#
#   Store all pending lazy operations (if any)
#
#   This method is only needed if some operation
#   was used using lazy flag
#
sub save
{
    my ($self, $control) = @_;

    $control = [] unless $control;
    my $result = $self->_entry->update($self->_ldap->ldbCon(), control => $control);
    if ($result->is_error()) {
        unless ($result->code == LDAP_LOCAL_ERROR and $result->error eq 'No attributes to update') {
            throw EBox::Exceptions::External(__('There was an error updating LDAP: ') . $result->error());
        }
    }
}

# Method: entryOpChangesInUpdate
#
#  string with the pending changes in a LDAP entry. This string is intended to
#  be used only for human consumption
#
#  Warning:
#   a entry with a failed update preserves the failed changes. This is
#   not documented in Net::LDAP so it could change in the future
#
sub entryOpChangesInUpdate
{
    my ($self, $entry) = @_;
    local $Data::Dumper::Terse = 1;
    my @changes = $entry->changes();
    my $args = $entry->changetype() . ' ' . Dumper(\@changes);
    return $args;
}

# Method: dn
#
#   Return DN for this object
#
sub dn
{
    my ($self) = @_;

    return $self->_entry->dn();
}

# Method: baseDn
#
#   Return base DN for this object
#
sub baseDn
{
    my ($self, $dn) = @_;
    if (not $dn and ref $self) {
        $dn = $self->dn();
    } elsif (not $dn) {
        throw EBox::Exceptions::MissingArgument("Called as class method and no DN supplied");
    }

    return $dn if ($self->_ldap->dn() eq $dn);

    my ($trash, $basedn) = split(/,/, $dn, 2);
    return $basedn;
}

# Method: _entry
#
#   Return Net::LDAP::Entry entry for the object
#
sub _entry
{
    my ($self) = @_;

    unless ($self->{entry}) {
        my $result = undef;
        if (defined $self->{dn}) {
            my $dn = $self->{dn};
            my $attrs = {
                base => $dn,
                filter => "(distinguishedName=$dn)",
                scope => 'base',
                attrs => ['*', 'unicodePwd', 'supplementalCredentials'],
            };
            $result = $self->_ldap->search($attrs);
        }
        return undef unless defined $result;

        if ($result->count() > 1) {
            throw EBox::Exceptions::Internal(
                __x('Found {count} results for, expected only one.',
                    count => $result->count()));
        }

        $self->{entry} = $result->entry(0);
    }

    return $self->{entry};
}

sub _sambaMod
{
    if (not $_sambaMod) {
        $_sambaMod = EBox::Global->getInstance(0)->modInstance('samba')
    }
    return $_sambaMod;
}

# Method: _ldap
#
#   Returns the LDAP object
#
sub _ldap
{
    my ($self) = @_;

    return _sambaMod()->ldb();
}

# Method: to_ldif
#
#   Returns a string containing the LDAP entry as LDIF
#
sub as_ldif
{
    my ($self) = @_;

    return $self->_entry->ldif(change => 0);
}

sub _guidToString
{
    my ($self, $guid) = @_;

    return sprintf "%08X-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X",
           unpack("I", $guid),
           unpack("S", substr($guid, 4, 2)),
           unpack("S", substr($guid, 6, 2)),
           unpack("C", substr($guid, 8, 1)),
           unpack("C", substr($guid, 9, 1)),
           unpack("C", substr($guid, 10, 1)),
           unpack("C", substr($guid, 11, 1)),
           unpack("C", substr($guid, 12, 1)),
           unpack("C", substr($guid, 13, 1)),
           unpack("C", substr($guid, 14, 1)),
           unpack("C", substr($guid, 15, 1));
}

sub _stringToGuid
{
    my ($self, $guidString) = @_;

    return undef
        unless $guidString =~ /([0-9,a-z]{8})-([0-9,a-z]{4})-([0-9,a-z]{4})-([0-9,a-z]{2})([0-9,a-z]{2})-([0-9,a-z]{2})([0-9,a-z]{2})([0-9,a-z]{2})([0-9,a-z]{2})([0-9,a-z]{2})([0-9,a-z]{2})/i;

    return pack("I", hex $1) . pack("S", hex $2) . pack("S", hex $3) .
           pack("C", hex $4) . pack("C", hex $5) . pack("C", hex $6) .
           pack("C", hex $7) . pack("C", hex $8) . pack("C", hex $9) .
           pack("C", hex $10) . pack("C", hex $11);
}

sub setCritical
{
    my ($self, $critical, $lazy) = @_;

    if ($critical) {
        $self->set('isCriticalSystemObject', 'TRUE', 1);
    } else {
        $self->delete('isCriticalSystemObject', 1);
    }

    my $relaxOidControl = Net::LDAP::Control->new(
        type => '1.3.6.1.4.1.4203.666.5.12',
        critical => 0 );
    $self->save($relaxOidControl) unless $lazy;
}

sub setViewInAdvancedOnly
{
    my ($self, $enable, $lazy) = @_;

    if ($enable) {
        $self->set('showInAdvancedViewOnly', 'TRUE', 1);
    } else {
        $self->delete('showInAdvancedViewOnly', 1);
    }
    my $relaxOidControl = Net::LDAP::Control->new(
        type => '1.3.6.1.4.1.4203.666.5.12',
        critical => 0 );
    $self->save($relaxOidControl) unless $lazy;
}

sub getXidNumberFromRID
{
    my ($self) = @_;

    my $sid = $self->sid();
    my $rid = (split (/-/, $sid))[7];

    return $rid + 50000;
}

# Method: parent
#
#   Return the parent of this object or undef if it's the root.
#
#   Throw EBox::Exceptions::Internal on error.
#
# TODO
#   bug: dns with same or less commponents of root DN are not treated properly
sub parent
{
    my ($self, $dn) = @_;
    if (not $dn and ref $self) {
        $dn = $self->dn();
    } elsif (not $dn) {
        throw EBox::Exceptions::MissingArgument("Called as class method and no DN supplied");
    }
    my $sambaMod = $self->_sambaMod();


    my $defaultNamingContext = $sambaMod->defaultNamingContext();
    return undef if ($dn eq $defaultNamingContext->dn());

    my $parentDn = $self->baseDn($dn);
    return $sambaMod->objectFromDN($parentDn);
}

sub relativeDn
{
    my ($self, $dnBase, $dn) = @_;
    if (not $dn and ref $self) {
        $dn = $self->dn();
    } elsif (not $dn) {
        throw EBox::Exceptions::MissingArgument("Called as class method and no DN supplied");
    }

    if (not $dn =~ s/,$dnBase$//) {
        throw EBox::Exceptions::Internal("$dn is not contained in $dnBase");
    }

    return $dn;
}

1;
