package Net::OAuth::All;
use warnings;
use strict;
use Carp 'croak';
use Encode;
use URI;
use URI::Escape;
use Net::OAuth::All::Config;

our $VERSION = '0.5';

use constant OAUTH_PREFIX => 'oauth_';

our $OAUTH_PREFIX_RE = do {my $p = OAUTH_PREFIX; qr/^$p/};

sub new {
	my ($class, %args) = @_;
	$args{'current_request_type'}   = '';
	$args{'request_method'      } ||= 'GET';
	($args{'module_version'} = version_autodetect(\%args)) =~ s/\./\_/;
	$args{'__BASE_CONFIG'  }   = Net::OAuth::All::Config::CONFIG->{$args{'module_version'}} || {};
	croak 'Your Net::OAuth::All::Config is empty. Check "module_version" config!' unless %{ $args{'__BASE_CONFIG'} };
	
	if ($args{'signature_method'} && $args{'signature_method'} eq 'RSA-SHA1') {
		croak "Param 'signature_key_file' is null or file doesn`t exists" unless $args{'signature_key_file'} && -f $args{'signature_key_file'};
		
		smart_require('Crypt::OpenSSL::RSA', 1);
		smart_require('File::Slurp',         1);
		
		my $key = File::Slurp::read_file($args{'signature_key_file'});
		$args{'signature_key'} = Crypt::OpenSSL::RSA->new_private_key( $key );
	}
	
	bless \%args => $class;
}

sub version_autodetect {
	my $args = shift;
	
	return $args->{'module_version'} if $args->{'module_version'};
	return '1.0' unless grep {!$args->{$_}} qw/consumer_key consumer_secret/;
	return '2.0' unless grep {!$args->{$_}} qw/client_id client_secret/;
}

sub request {
	my ($self, $request_type, %args) = @_;
	
	croak "Request $request_type not suppoted!" unless %{ $self->base_requestconfig($request_type) };
	
	$self->{'current_request_type'}  = $request_type;
	$self->{$_} = $args{$_} for keys %args;
	
	$self->check;
	$self->preload;
	return $self;
}

sub response {
	my ($self, $type, %args) = @_;
	delete $self->{$_} for qw/token token_secret/;
	return $self;
}

sub preload {
	my $self = shift;
	$self->{'timestamp'} = time;
	$self->{'nonce'    } = $self->gen_str;
	$self->sign if $self->sign_message;
}

sub check {
	my $self = shift;
	croak "Missing required parameter '$_'" for grep {not defined $self->{$_}} $self->required_params;
	
	#~ if ($self->{'extra_params'} && $self->allow_extra_params) {
		#~ croak "Parameter '$_' not allowed in arbitrary params" for grep {$_=~ $OAUTH_PREFIX_RE} keys %{$self->{extra_params}};
	#~ }
}

sub base_requestconfig {
	my ($self, $request_type) = @_;
	$request_type ||= $self->{'current_request_type'};
	
	return (
		($self->{'module_version'} eq '2_0' and not grep {$request_type =~ /$_/} qw/refresh protected/)
			?
				$self->{'__BASE_CONFIG'}->{$self->{'type'}}->{$request_type}
			:
				$self->{'__BASE_CONFIG'}->{$request_type}
	) || {};
}

sub allow_extra_params {1}

sub gather_message_parameters {
	my ($self, %opts) = @_;
	
	$opts{'quote'}   = "" unless defined $opts{'quote'};
	$opts{'add'  } ||= [];
	
	my %params = ();
	if ($self->{'module_version'} eq '2_0') {
		%params = map {$_ => $self->{$_}}
			$self->api_params, grep {$self->{$_}} $self->optional_params, , @{$opts{add}};
	} else {
		%params = 
			map  {OAUTH_PREFIX.$_ => $self->{$_}}
			grep {( $_ eq 'signature' && (!$self->sign_message || !grep ( $_ eq 'signature', @{$opts{add}} )) ) ? 0 : 1}
			$self->api_params, grep {$self->{$_}} $self->optional_params, , @{$opts{add}};
		if ($self->{'extra_params'} && !$opts{'no_extra'} && $self->allow_extra_params) {
			$params{$_} = $self->{'extra_params'}{$_} for keys %{$self->{'extra_params'}};
		}
	}
	
	return \%params if $opts{'hash'};
	
	return sort map {join '=', escape($_), $opts{'quote'} . escape($params{$_}) . $opts{'quote'}} keys %params;
}

sub to_authorization_header {
	my ($self, $realm, $sep) = @_;
	$sep  ||= ",";
	$realm  = defined $realm ? "realm=\"$realm\"$sep" : "";
	
	return "OAuth $realm" .
		join($sep, $self->gather_message_parameters(quote => '"', add => [qw/signature/], no_extra => 1));
}

sub to_url {
	my ($self, $url) = @_;
	if (!defined $url and $self->can('request_url') and defined $self->request_url) {
		$url = $self->request_url;
	}
	if (defined $url) {
		_ensure_uri_object($url);
		$url = $url->clone; # don't modify the URL that was passed in
		$url->query(undef); # remove any existing query params, as these may cause the signature to break	
		my $params = $self->to_hash;
		return $url . '?' . join '&', map {escape($_) . '=' . escape( $params->{$_} )} sort keys %$params;
	} else {
		croak "Can`t load $self->{'current_request_type'} request URL";
	}
}

sub from_hash {
	my ($self, $hash) = @_;
	croak 'Expected a hash!' if ref $hash ne 'HASH';
	
	if ($self->{'module_version'} eq '2_0') {
		$self->{$_} = $hash->{$_} for keys %$hash;
	} else {
		foreach my $k (keys %$hash) {
			if ($k =~ s/$OAUTH_PREFIX_RE//) {
				$self->{$k} = $hash->{OAUTH_PREFIX . $k};
			} else {
				$self->{'extra_params'}->{$k} = $hash->{$k};
			}
		}
	}
	
	return $self;
}

sub to_hash      { shift->gather_message_parameters(hash => 1, add => [qw/signature/]) }
sub to_post_body { join '&', shift->gather_message_parameters(add => [qw/signature/])  }

sub from_post_body {
	my ($self, $post_body) = @_;
	croak "Provider sent error message '$post_body'" if $post_body =~ /\s/;
	return $self->from_hash({map {unescape($_)} grep {s/(^"|"$)//g;1;} map {split '=', $_, 2} split '&', $post_body});
}

#sign
sub sign {
	my $self = shift;
	my $class = $self->_signature_method_class;
	$self->signature($class->sign($self, @_));
}

sub _signature_method_class {
	my $self = shift;
	(my $signature_method = $self->signature_method) =~ s/\W+/_/g;
	my $sm_class = 'Net::OAuth::All::SignatureMethod::' . $signature_method;
	croak "Unable to load $signature_method signature plugin. Check signature_method" unless smart_require($sm_class);
	return $sm_class;
}

sub signature_key {
	my $self = shift;
	# For some sig methods (I.e. RSA), users will pass in their own key
	my $key = $self->{'signature_key'};
	unless (defined $key) {
		$key = escape($self->{'consumer_secret'}) . '&';
		$key .= escape($self->{'token_secret'}) if $self->{'token_secret'};
	}
	return $key;
}

sub sign_message {+shift->{'__BASE_CONFIG'}->{'sign_message'} || 0}
sub _ensure_uri_object { $_[0] = UNIVERSAL::isa($_[0], 'URI') ? $_[0] : URI->new($_[0]) }

sub normalized_request_url {
	my $self = shift;
	my $url = $self->request_url;
	_ensure_uri_object($url);
	$url = $url->clone;
	$url->query(undef);
	return $url;
}

sub normalized_message_parameters { join '&',  shift->gather_message_parameters }
sub signature_base_string {
	my $self = shift;
	return join '&', map {escape($self->$_)} qw/request_method normalized_request_url normalized_message_parameters/;
}

#----------------

our %ALREADY_REQUIRED = ();

sub smart_require {
	my $required_class = shift;
	my $croak_on_error = shift || 0;
	unless (exists $ALREADY_REQUIRED{$required_class}) {
		$ALREADY_REQUIRED{$required_class} = eval "require $required_class";
		croak $@ if $@ and $croak_on_error;
	}
	return $ALREADY_REQUIRED{$required_class};
}

#params list
sub required_params { @{ shift->base_requestconfig->{'required_params'} || {}} }
sub api_params      { @{ shift->base_requestconfig->{'api_params'     } || {}} }
sub optional_params { @{ shift->base_requestconfig->{'optional_params'} || {}} }

#take params
sub token {
	for (+shift) {
		return $_->{ $_->{'module_version'} eq '2_0' ? 'access_token' : 'token' };
	}
}

sub token_secret  { shift->{'token_secret' }       }
sub expires       { shift->{'expires'      } || 0  }
sub scope         { shift->{'scope'        } || '' }
sub refresh_token { shift->{'refresh_token'} || '' }
sub request_url   {
	my $self = shift;
	$self->{$self->{'current_request_type'}."_url"};
}
sub signature {
	my ($self, $value) = @_;
	$self->{'signature'} = $value if defined $value;
	
	return $self->{'signature'};
}

sub signature_method {
	my ($self, $value) = @_;
	$self->{'signature_method'} = $value if defined $value;
	
	return $self->{'signature_method'} || '';
}

sub request_method {
	my ($self, $value) = @_;
	$self->{'request_method'} = $value if defined $value;
	
	return $self->{'request_method'};
}

#extra subs
sub escape {
	my $str = shift || "";
	$str = Encode::decode_utf8($str, 1) if $str =~ /[\x80-\xFF]/ && Encode::is_utf8($str);
	
	return URI::Escape::uri_escape_utf8($str,'^\w.~-');
}

sub unescape { uri_unescape(shift) }

our $tt = [0..9, 'a'..'z', 'A'..'Z'];

sub gen_str { join '', map {$tt->[rand @$tt]} 1..16 }

1;