use strict;
use warnings;

package Locale::Simple::Scraper::Parser;

use base qw( Parser::MGC );

use Moo;
use Try::Tiny;

has func_qr => ( is => 'ro', default => sub { qr/\bl(|n|p|np|d|dn|dnp)\b/ } );
has debug_sub => (
    is      => 'ro',
    default => sub {
        sub { shift, warn "- " . sprintf shift . "\n", @_ }
    }
);
has found => ( is => 'ro', default => sub { [] } );
has type => ( is => 'ro', required => 1 );

sub debug { shift->debug_sub->( @_ ) }

sub parse {
    my ( $self ) = @_;
    $self->sequence_of(
        sub {
            $self->any_of( sub { $self->noise }, sub { $self->call } );
        }
    );
    return $self->found;
}

sub noise {
    my ( $self ) = @_;
    my $noise = $self->substring_before( $self->func_qr );
    $self->fail( "no noise found" ) if !length $noise;
    $self->debug( "discarded %d characters of noise", length $noise );
    return $noise;
}

sub call {
    my ( $self ) = @_;
    my $func = $self->expect( $self->func_qr );
    $self->debug( "found func $func at line %d", ( $self->where )[0] );

    try { $self->arguments( $func ) }
    catch {
        die $_ if !eval { $_->isa( "Parser::MGC::Failure" ) };
        $self->warn_failure( $_ );
    };

    return;
}

sub arguments {
    my ( $self, $func ) = @_;

    {    # force the debug output to point at the position after the func name
        local $self->{patterns}{ws} = qr//;
        $self->expect_string( "(" );
    }

    my $args_method = "required_args_$func";
    my @arguments = ( $self->$args_method, $self->extra_arguments );

    $self->expect_string( ")" );

    $self->debug( "found %d arguments", scalar @arguments );
    push @{ $self->found }, { func => $func, args => \@arguments, line => ( $self->where )[0] };

    return;
}

sub expect_string { $_[0]->maybe_expect( "$_[1]" ) or $_[0]->fail( "Expected \"$_[1]\"" ) }

sub extra_arguments {
    my ( $self ) = @_;
    return if !$self->maybe_expect( "," );

    my $extra_args = $self->list_of(
        ",",
        sub {
            $self->any_of(
                sub { $self->call },
                sub { $self->dynamic_string },
                sub { $self->token_int },
                sub { $self->variable }
            );
        }
    );
    return @{$extra_args};
}

sub required_args_l    { shift->collect_from( qw( translation_token ) ) }
sub required_args_ln   { shift->collect_from( qw( translation_token  comma  plural_args ) ) }
sub required_args_lp   { shift->collect_from( qw( context_id         comma  translation_token ) ) }
sub required_args_lnp  { shift->collect_from( qw( required_args_lp   comma  plural_args ) ) }
sub required_args_ld   { shift->collect_from( qw( domain_id          comma  translation_token ) ) }
sub required_args_ldn  { shift->collect_from( qw( domain_id          comma  required_args_ln ) ) }
sub required_args_ldnp { shift->collect_from( qw( domain_id          comma  required_args_lnp ) ) }

sub plural_args { shift->collect_from( qw( plural_token  comma  plural_count ) ) }

sub collect_from {
    my ( $self, @methods ) = @_;
    return map { $self->$_ } @methods;
}

sub translation_token { shift->named_token( "translation token" ) }
sub plural_token      { shift->named_token( "plural translation token" ) }
sub plural_count      { shift->named_token( "count of plural entity", "token_int" ) }
sub context_id        { shift->named_token( "context id" ) }
sub domain_id         { shift->named_token( "domain id" ) }
sub comma             { shift->expect_string( "," ); () }                               # consume, no output
sub variable          { shift->expect( qr/[\w\.]+/ ) }

sub named_token {
    my ( $self, $name, $type ) = @_;
    $type ||= "constant_string";
    my $token = $self->maybe( sub { $self->$type } ) or $self->fail( "Expected $name" );
    return $token;
}

sub constant_string {
    my ( $self, @extra_components ) = @_;

    my $p = $self->{patterns};

    my $string = $self->list_of(
        $self->concat_op,
        sub {
            my $string = $self->any_of(
                sub {
                    $self->scope_of( q["], sub { local $p->{ws} = qr//; $self->double_quote_string_contents }, q["] );
                },
                sub {
                    $self->scope_of( q['], sub { local $p->{ws} = qr//; $self->single_quote_string_contents }, q['] );
                },
                @extra_components,
            );
        }
    );

    return join "", @{$string} if @{$string};

    $self->fail;
}

sub concat_op {
    my %ops = ( js => "+", pl => ".", tx => "_", py => "+" );
    return $ops{ shift->type };
}

sub dynamic_string {
    my ( $self ) = @_;
    return $self->constant_string( sub { $self->variable } );
}

sub double_quote_string_contents {
    my ( $self ) = @_;
    return $self->string_contents( sub { $self->expect( qr/[^\\"]+/ ) }, sub { $self->expect_escaped( q["] ) }, );
}

sub single_quote_string_contents {
    my ( $self ) = @_;
    return $self->string_contents(
        sub { $self->expect( qr/[^\\']+/ ) },
        sub { $self->expect_escaped( q['] ) },
        sub { $self->expect_escaped( q[\\] ) },
        sub { $self->expect( qr/\\/ ) },
    );
}

sub string_contents {
    my ( $self, @contents ) = @_;
    my $elements = $self->sequence_of( sub { $self->any_of( @contents ) } );
    return join "", @{$elements} if @{$elements};
    $self->fail( "no string contents found" );
}

sub expect_escaped { $_[0]->expect( qr/\\\Q$_[1]\E/ ); $_[1] }

sub warn_failure {
    my ( $self, $f ) = @_;
    my ( $linenum, $col, $text ) = $self->where( $f->{pos} || $self->pos );
    my $indent = substr( $text, 0, $col );
    $_ =~ s/\t/    /g for $text, $indent;
    $indent =~ s/./-/g;     # blank out all the non-whitespace
    $text   =~ s/\%/%%/g;
    $self->debug( "$f->{message}:\n |$text\n |$indent^" );
    return;
}

1;
