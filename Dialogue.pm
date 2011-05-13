package Dialogue;
use Moose;

has 'person'  => (is => 'rw', isa => 'Str');
has 'channel' => (is => 'rw', isa => 'Str');
has 'content' => (is => 'rw', isa => 'Str');

has 'reply' => (is => 'rw', isa => 'CodeRef');
has 'say'   => (is => 'rw', isa => 'CodeRef');
has 'me'    => (is => 'rw', isa => 'CodeRef');

__PACKAGE__->meta->make_immutable;
1;
