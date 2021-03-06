package DADA::App::MassSend;

use lib qw(
  ../../
  ../../DADA/perllib
);

use DADA::Config qw(!:DEFAULT);
use DADA::App::Guts;
use DADA::Template::HTML;
use DADA::MailingList::Archives;
use DADA::MailingList::Settings;
use DADA::MailingList::Subscribers;
use DADA::MailingList::MessageDrafts;
use Try::Tiny;

use Carp qw(carp croak);

#$Carp::Verbose = 1;

use strict;
use vars qw($AUTOLOAD);

my $t = $DADA::Config::DEBUG_TRACE->{DADA_App_MassSend};

my %allowed = ( test => 0, );

sub new {

    my $that = shift;
    my $class = ref($that) || $that;

    my $self = {
        _permitted => \%allowed,
        %allowed,
    };

    bless $self, $class;

    my ($args) = @_;

    $self->_init($args);
    return $self;
}

sub AUTOLOAD {
    my $self = shift;
    my $type = ref($self)
      or croak "$self is not an object";

	return if(substr($AUTOLOAD, -7) eq 'DESTROY');

    my $name = $AUTOLOAD;
    $name =~ s/.*://;    #strip fully qualifies portion

    unless ( exists $self->{_permitted}->{$name} ) {
        croak "Can't access '$name' field in object of class $type";
    }
    if (@_) {
        return $self->{$name} = shift;
    }
    else {
        return $self->{$name};
    }
}

sub _init {

    my $self = shift;
    my ($args) = @_;

    if ( !exists( $args->{-list} ) ) {
        croak "You must pass the -list parameter!";
    }
    else {
        $self->{list} = $args->{-list};
    }

    $self->{ls_obj} = DADA::MailingList::Settings->new( { -list => $self->{list} } );
    $self->{lh_obj} = DADA::MailingList::Subscribers->new( { -list => $self->{list} } );
    $self->{ah_obj} = DADA::MailingList::Archives->new( { -list => $self->{list} } );
    $self->{md_obj} = DADA::MailingList::MessageDrafts->new( { -list => $self->{list} } );

}

sub send_email {
    warn 'send_email'
      if $t;

    my $self = shift;
    my ($args) = @_;

    my $q          = $args->{-cgi_obj};
    my $root_login = $args->{-root_login};

    my $process            = xss_filter( strip( scalar $q->param('process') ) );
    my $flavor             = xss_filter( strip( scalar $q->param('flavor') ) );
    my $restore_from_draft = xss_filter( strip( scalar $q->param('restore_from_draft') ) ) || 'true';
    my $test_sent          = xss_filter( strip( scalar $q->param('test_sent') ) ) || 0;
    my $test_recipient     = xss_filter( strip( scalar $q->param('test_recipient') ) );
    my $done               = xss_filter( strip( scalar $q->param('done') ) ) || 0;
    my $draft_role         = $q->param('draft_role') || 'draft';
    my $ses_params         = $self->ses_params;

    if ( !exists( $args->{-html_output} ) ) {
        $args->{-html_output} = 1;
    }

    my $li = $self->{ls_obj}->get( -all_settings => 1 );

    my $naked_fields = $self->{lh_obj}->subscriber_fields( { -dotted => 0 } );
    my $fields = [];

    # Extra, special one...
    push( @$fields, { name => 'subscriber.email' } );
    for my $field ( @{ $self->{lh_obj}->subscriber_fields( { -dotted => 1 } ) } ) {
        push( @$fields, { name => $field } );
    }
    my $undotted_fields = [];

    # Extra, special one...
    push( @$undotted_fields, { name => 'email', label => 'Email Address' } );
    require DADA::ProfileFieldsManager;
    my $pfm         = DADA::ProfileFieldsManager->new;
    my $fields_attr = $pfm->get_all_field_attributes;
    for my $undotted_field ( @{$naked_fields} ) {
        push(
            @$undotted_fields,
            {
                name  => $undotted_field,
                label => $fields_attr->{$undotted_field}->{label}
            }
        );
    }

    if ( !$process ) {

        warn '!$process'
          if $t;

        my ( $num_list_mailouts, $num_total_mailouts, $active_mailouts, $mailout_will_be_queued ) =
          $self->mass_mailout_info;

        my $draft_id = $self->find_draft_id(
            {
                -screen  => 'send_email',
                -role    => $draft_role,
                -cgi_obj => $q,
            }
        );

        require DADA::Template::Widgets;
        my %wysiwyg_vars = DADA::Template::Widgets::make_wysiwyg_vars( $self->{list} );
        my $scrn         = 'send_email';

        my $scrn = DADA::Template::Widgets::wrap_screen(
            {
                -screen         => 'send_email_screen.tmpl',
                -with           => 'admin',
                -expr           => 1,
                -wrapper_params => {
                    -Root_Login => $root_login,
                    -List       => $self->{list},
                },
                -vars => {
                    screen                     => 'send_email',
                    flavor                     => $flavor,
                    draft_id                   => $draft_id,
                    draft_role                 => $draft_role,
                    restore_from_draft         => $restore_from_draft,
                    done                       => $done,
                    test_sent                  => $test_sent,
                    test_recipient             => $test_recipient,
                    priority_popup_menu        => DADA::Template::Widgets::priority_popup_menu($li),
                    type                       => 'list',
                    fields                     => $fields,
                    undotted_fields            => $undotted_fields,
                    can_have_subscriber_fields => $self->{lh_obj}->can_have_subscriber_fields,

                    # I don't really have this right now...
                    MAILOUT_AT_ONCE_LIMIT => $DADA::Config::MAILOUT_AT_ONCE_LIMIT,
                    kcfinder_url          => $DADA::Config::FILE_BROWSER_OPTIONS->{kcfinder}->{url},
                    kcfinder_upload_dir   => $DADA::Config::FILE_BROWSER_OPTIONS->{kcfinder}->{upload_dir},
                    kcfinder_upload_url   => $DADA::Config::FILE_BROWSER_OPTIONS->{kcfinder}->{upload_url},
                    core5_filemanager_url => $DADA::Config::FILE_BROWSER_OPTIONS->{core5_filemanager}->{url},
                    core5_filemanager_upload_dir =>
                      $DADA::Config::FILE_BROWSER_OPTIONS->{core5_filemanager}->{upload_dir},
                    core5_filemanager_upload_url =>
                      $DADA::Config::FILE_BROWSER_OPTIONS->{core5_filemanager}->{upload_url},
                    mailout_will_be_queued => $mailout_will_be_queued,
                    num_list_mailouts      => $num_list_mailouts,
                    num_total_mailouts     => $num_total_mailouts,
                    active_mailouts        => $active_mailouts,
                    schedule_last_checked_frt => scalar formatted_runtime( time - $self->{ls_obj}->param('schedule_last_checked_time') ),
                      can_use_datetime => scalar DADA::App::Guts::can_use_datetime(), 
                      sched_flavor => $DADA::Config::SCHEDULED_JOBS_OPTIONS->{scheduled_jobs_flavor},
                    %wysiwyg_vars,
                    %$ses_params,
                },
                -list_settings_vars       => $li,
                -list_settings_vars_param => { -dot_it => 1, },
            }
        );
        if ( $restore_from_draft eq 'true' ) {
            $scrn = $self->fill_in_draft_msg(
                {
                    -list     => $self->{list},
                    -screen   => 'send_email',
                    -str      => $scrn,
                    -draft_id => $draft_id,
                    -role     => $draft_role,

                }
            );
        }
        return ( {}, $scrn );
    }
    elsif ( $process eq 'save_as_draft' ) {

        # Utterly out of place
        # save_as_draft called via js
        my ( $headers, $body ) = $self->save_as_draft(
            {
                -cgi_obj => $q,
                -list    => $self->{list},
                -json    => 1,
            }
        );
        return ( $headers, $body );
    }
    else {
        # Draft now has all our form params
        # draft_id and role will be saved in $q

        my $draft_id = $self->save_as_draft(
            {
                -cgi_obj => $q,
                -list    => $self->{list},
                -json    => 0,
            }
        );
        # to fetch a draft, I need id, list and role (lame)
        my ( $status, $errors, $message_id, $md5 ) = $self->construct_and_send(
            {
                -draft_id => $draft_id,
                -screen   => 'send_email',
                -role     => $draft_role,
                -process  => $process,
            }
        );
        if($t) { 
            carp '$message_id ' . $message_id;
            carp 'done with construct_and_send!';
        }
        if ( $status == 0 ) {
            return $self->report_mass_mail_errors( $errors, $root_login );
        }

        if ( $process =~ m/test/i ) {
            warn 'test sending'
              if $t;

            $self->wait_for_it($message_id);
            return (
                {
                        -redirect_uri => $DADA::Config::S_PROGRAM_URL
                      . '?flavor='
                      . $flavor
                      . '&test_sent=1&test_recipient='
                      . $q->param('test_recipient')
                      . '&draft_id='
                      . $q->param('draft_id')
                      . '&restore_from_draft='
                      . $q->param('restore_from_draft')
                      . '&draft_role='
                      . $q->param('draft_role')
                },
                undef
            );
        }
        else {
            if ( defined($draft_id) ) {
                $self->{md_obj}->remove($draft_id);
            }
            my $uri;
            if ( $q->param('archive_no_send') == 1 && $q->param('archive_message') == 1 ) {
                $uri = $DADA::Config::S_PROGRAM_URL . '?flavor=view_archive&id=' . $message_id;
            }
            else {
                $uri = $DADA::Config::S_PROGRAM_URL . '?flavor=sending_monitor&type=list&id=' . $message_id;
            }
            return ( { -redirect_uri => $uri }, undef );
        }
    }
}

sub are_we_archiving_based_on_params {

    my $self = shift;
    my $q = shift || undef;
    if ( defined($q) ) {
        if ( defined( $q->param('local_archive_options_present') ) ) {
            if ( $q->param('local_archive_options_present') == 1 ) {
                if ( $q->param('archive_message') != 1 ) {
                    $q->param( 'archive_message', 0 );
                    return 0;
                }
                else {
                    return 1;
                }
            }
        }
        else {
            return $self->{ls_obj}->param('archive_messages');
        }
    }
    else {
        return $self->{ls_obj}->param('archive_messages');
    }
}

sub construct_and_send {
    warn 'construct_and_send'
      if $t;

    my $self = shift;
    my ($args) = @_;

    #if($t == 1){
    #require Data::Dumper;
    #warn 'args:' . Data::Dumper::Dumper($args);
    #}

    my $draft_q = undef;
       $draft_q = $self->q_obj_from_draft($args);

    my $process    = $args->{-process};
    my $status     = 0;
    my $errors     = undef;
    my $message_id = undef;
    my $entity     = undef;
    my $fm         = undef;
    my $md5        = undef; 
    my $dry_run    = 0; 
    
    if ( exists($args->{-dry_run})) {
        $dry_run = $args->{-dry_run};
    }
    
    if ( $args->{-screen} eq 'send_email' ) {
        ( $status, $errors, $entity, $fm ) = $self->construct_from_text($draft_q);
    }
    elsif ( $args->{-screen} eq 'send_url_email' ) {
        ( $status, $errors, $entity, $fm, $md5 ) = $self->construct_from_url($draft_q);
    }
    else {
        croak "unknown screen: " . $args->{-screen};
    }

    if ( $status == 0 && $t == 1 ) {
        warn '$errors: ' . $errors;
    }
    if ( $status == 0 ) {
        return ( 0, $errors, undef, undef );
    }

    # Good? Alright.
    my $msg_as_string = ( defined($entity) ) ? $entity->as_string : undef;
    $msg_as_string = safely_decode($msg_as_string);

    #    $fm->Subject( $headers{Subject} );

    my ( $final_header, $final_body );
    try { 
        ( $final_header, $final_body ) = $fm->format_headers_and_body( -msg => $msg_as_string ); 
    } catch { 
        return ( 0, $@, undef, undef );
    };

    if($dry_run != 1) { 
        require DADA::Mail::Send;
        my $mh = DADA::Mail::Send->new(
            {
                -list   => $self->{list},
                -ls_obj => $self->{ls_obj},
            }
        );

        unless ( $mh->isa('DADA::Mail::Send') ) {
            return ( 0, "DADA::Mail::Send object wasn't created correctly?", undef, undef );
        }

        $mh->test( $self->test );

        my %mailing = ( $mh->return_headers($final_header), Body => $final_body, );

        my $naked_fields = $self->{lh_obj}->subscriber_fields( { -dotted => 0 } );
        my $partial_sending = partial_sending_query_to_params( $draft_q, $naked_fields );

        if ( $draft_q->param('archive_no_send') != 1 ) {
            my @alternative_list = ();
            @alternative_list = $draft_q->multi_param('alternative_list');
            $mh->mass_test_recipient( scalar $draft_q->param('test_recipient') );
            my $multi_list_send_no_dupes = $draft_q->param('multi_list_send_no_dupes')
              || 0;

            if ( exists( $args->{-Ext_Request} ) ) {
                $mh->Ext_Request( $args->{-Ext_Request} );
            }

            $message_id = $mh->mass_send(
                {
                    -msg             => {%mailing},
                    -partial_sending => $partial_sending,
                    -multi_list_send => {
                        -lists    => [@alternative_list],
                        -no_dupes => $multi_list_send_no_dupes,
                    },
                    -also_send_to => [@alternative_list],
                    ( $process =~ m/test/i )
                    ? (
                        -mass_test      => 1,
                        -test_recipient => $draft_q->param('test_recipient'),
                      )
                    : ( -mass_test => 0, )

                }
            );
        }
        else {

            if ( $draft_q->param('back_date') == 1 ) {
                $message_id = $self->backdated_msg_id( $draft_q->param('backdate_datetime') );
            }
            else {
                $message_id = DADA::App::Guts::message_id();
            }

            %mailing = $mh->clean_headers(%mailing);
            %mailing = ( %mailing, $mh->_make_general_headers, $mh->list_headers );

            require DADA::Security::Password;
            my $ran_number = DADA::Security::Password::generate_rand_string('1234567890');
            $mailing{'Message-ID'} =
              '<' . $message_id . '.' . $ran_number . '.' . $self->{ls_obj}->param('list_owner_email') . '>';
            $mh->saved_message( $mh->_massaged_for_archive( \%mailing ) );

        }

        if ( ( $self->are_we_archiving_based_on_params($draft_q) == 1 ) && ( $process !~ m/test/i ) ) {
            $self->{ah_obj}->set_archive_info( $message_id, $mailing{Subject}, undef, undef, $mh->saved_message );
        }

        return ( 1, undef, $message_id, $md5 );
    }
    else { 
        # Dry run: 
        return ( 1, undef, undef, $md5 );
    }
}

sub construct_from_text {
    warn 'construct_from_text'
      if $t;

    my $self    = shift;
    my $draft_q = shift;

    require DADA::App::FormatMessages;
    my $fm = DADA::App::FormatMessages->new( -List => $self->{list} );
    $fm->mass_mailing(1);

    my %headers = ();
    for my $h (
        qw(
        Reply-To
        Return-Path
        X-Priority
        Subject
        )
      )
    {
        if ( defined( scalar $draft_q->param($h) ) ) {

            # I do not like how we treat Subject differently, but I don't have a better idea on what to do.
            if ( $h eq 'Subject' ) {
                $headers{$h} = $fm->_encode_header( 'Subject', scalar $draft_q->param($h) );
            }
            else {
                $headers{$h} = strip( scalar $draft_q->param($h) );
            }
        }
    }

    #/Headers

    require MIME::Entity;

    my $email_format      = $draft_q->param('email_format');
    my $attachment        = $draft_q->param('attachment');
    my $text_message_body = $draft_q->param('text_message_body') || undef;
    my $html_message_body = $draft_q->param('html_message_body') || undef;
    my @attachments       = $self->has_attachments( { -cgi_obj => $draft_q } );
    my $num_attachments   = scalar(@attachments);

    ( $text_message_body, $html_message_body ) =
      DADA::App::FormatMessages::pre_process_msg_strings( $text_message_body, $html_message_body );

    my $entity;

    if ( $html_message_body && $text_message_body ) {

        $text_message_body = safely_encode($text_message_body);
        $html_message_body = safely_encode($html_message_body);

        my ( $status, $errors ) = $self->message_tag_check($text_message_body);
        if ( $status == 0 ) {
            return ( $status, $errors, undef, undef );
        }
        undef($status);
        undef($errors);

        my ( $status, $errors ) = $self->message_tag_check($html_message_body);
        if ( $status == 0 ) {
            return ( $status, $errors, undef, undef );
        }
        undef($status);
        undef($errors);

        $entity = MIME::Entity->build(
            Type    => 'multipart/alternative',
            Charset => $self->{ls_obj}->param('charset_value'),
            ( ( $num_attachments < 1 ) ? (%headers) : () ),
        );
        $entity->attach(
            Type     => 'text/plain',
            Data     => $text_message_body,
            Encoding => $self->{ls_obj}->param('plaintext_encoding'),
            Charset  => $self->{ls_obj}->param('charset_value'),
        );
        $entity->attach(
            Type     => 'text/html',
            Data     => $html_message_body,
            Encoding => $self->{ls_obj}->param('html_encoding'),
            Charset  => $self->{ls_obj}->param('charset_value'),
        );

    }
    elsif ($html_message_body) {

        $html_message_body = safely_encode($html_message_body);

        my ( $status, $errors ) = $self->message_tag_check($html_message_body);
        if ( $status == 0 ) {
            return ( $status, $errors, undef, undef );
        }
        undef($status);
        undef($errors);

        $entity = MIME::Entity->build(
            Type     => 'text/html',
            Data     => $html_message_body,
            Encoding => $self->{ls_obj}->param('html_encoding'),
            Charset  => $self->{ls_obj}->param('charset_value'),
            ( ( $num_attachments < 1 ) ? (%headers) : () ),
        );
    }
    elsif ($text_message_body) {

        $text_message_body = safely_encode($text_message_body);

        my ( $status, $errors ) = $self->message_tag_check($text_message_body);
        if ( $status == 0 ) {
            return ( $status, $errors, undef, undef );
        }
        undef($status);
        undef($errors);

        $entity = MIME::Entity->build(
            Type     => 'text/plain',
            Data     => $text_message_body,
            Encoding => $self->{ls_obj}->param('plaintext_encoding'),
            Charset  => $self->{ls_obj}->param('charset_value'),
            ( ( $num_attachments < 1 ) ? (%headers) : () ),
        );
    }
    else {
        return ( 0, "There's no text in either the PlainText or HTML version of your email message!", undef, undef );
    }

    my @compl_att = ();
    if (@attachments) {
        my @compl_att = ();
        for (@attachments) {
            my ($attach_entity) = $self->make_attachment( { -name => $_, -cgi_obj => $draft_q } );
            push( @compl_att, $attach_entity )
              if $attach_entity;
        }
        if ( $compl_att[0] ) {
            my $mpm_entity = MIME::Entity->build(
                Type => 'multipart/mixed',
                %headers
            );
            $mpm_entity->add_part($entity);
            for (@compl_att) {

                #  warn 'add part
                $mpm_entity->add_part($_);
            }
            $entity = $mpm_entity;
        }
    }
    return ( 1, undef, $entity, $fm );
}

sub construct_from_url {

    my $self    = shift;
    my $draft_q = shift;

    require DADA::App::FormatMessages;
    my $fm = DADA::App::FormatMessages->new( -List => $self->{list} );
    $fm->mass_mailing(1);

    my $can_use_mime_lite_html = 0;
    my $mime_lite_html_error   = undef;
    eval { require DADA::App::MyMIMELiteHTML };
    if ( !$@ ) {
        $can_use_mime_lite_html = 1;
    }
    else {
        $mime_lite_html_error = $@;
    }

    if ( !$can_use_mime_lite_html ) {
        return ( 0, $@, undef, undef, undef );
    }

    my $url               = strip( $draft_q->param('url') );
    my $url_options       = $draft_q->param('url_options') || undef;
    my $remove_javascript = $draft_q->param('remove_javascript') || 0;

    my %headers = ();
    for my $h (
        qw(
        Reply-To
        Return-Path
        X-Priority
        Subject
        )
      )
    {
        if ( defined( $draft_q->param($h) ) ) {
            $headers{$h} = strip( $draft_q->param($h) );
        }
    }
    
    if($draft_q->param('subject_from') eq 'title_tag') { 
        
       my $url_subject = $self->subject_from_title_tag($draft_q); 
       if(defined($url_subject)){ 
            $headers{Subject} = $url_subject; 
        }
    }
    
    my $mailHTML = new DADA::App::MyMIMELiteHTML(
        remove_jscript                   => $remove_javascript,
        'IncludeType'                    => $url_options,
        'TextCharset'                    => scalar $self->{ls_obj}->param('charset_value'),
        'HTMLCharset'                    => scalar $self->{ls_obj}->param('charset_value'),
        HTMLEncoding                     => scalar $self->{ls_obj}->param('html_encoding'),
        TextEncoding                     => scalar $self->{ls_obj}->param('plaintext_encoding'),
        crop_html_content                => scalar $draft_q->param('crop_html_content'),
        crop_html_content_selector_type  => scalar $draft_q->param('crop_html_content_selector_type'),
        crop_html_content_selector_label => scalar $draft_q->param('crop_html_content_selector_label'),
        #( ($proxy)         ? ( Proxy        => $proxy, )         : () ),
        #( ($login_details) ? ( LoginDetails => $login_details, ) : () ),
        (
              ( $DADA::Config::CPAN_DEBUG_SETTINGS{MIME_LITE_HTML} == 1 )
            ? ( Debug => 1, )
            : ()
        ),
        %headers,
    );

    my $text_message = undef; 
    if ( defined(scalar $draft_q->param('text_message_body')) ) {
        $text_message = $draft_q->param('text_message_body');
    }
    else {
        $text_message = 'This email message requires that your mail reader support HTML';
    }
    if ( $draft_q->param('plaintext_content_from') eq 'auto' ) {
        if ( $draft_q->param('content_from') eq 'url' ) {
            if ( length($url) <= 0 ) {
                croak "You did not fill out a URL!";
            }
            my ( $good_try, $res, $md5 ) = grab_url({-url => $draft_q->param('url') });

            $text_message = html_to_plaintext(
                {
                    -str              => $good_try,
                    -formatter_params => {
                        base        => $url,
                        before_link => '<!-- tmpl_var LEFT_BRACKET -->%n<!-- tmpl_var RIGHT_BRACKET -->',
                        footnote    => '<!-- tmpl_var LEFT_BRACKET -->%n<!-- tmpl_var RIGHT_BRACKET --> %l',
                    }
                }
            );
        }
        else {
            $text_message = html_to_plaintext(
                {
                    -str => $draft_q->param('html_message_body')
                }
            );
        }
    }
    elsif ( $draft_q->param('plaintext_content_from') eq 'text' ) {        
		$text_message = $draft_q->param('text_message_body');
    }
	elsif ( $draft_q->param('plaintext_content_from') eq 'url' ) {        
        my $res; 
		my $md5; 
        ( $text_message, $res, $md5 ) = grab_url({-url => $draft_q->param('plaintext_url') });
    }

    my ( $status, $errors ) = $self->message_tag_check($text_message);
    if ( $status == 0 ) {
        return ( $status, $errors, undef, undef, undef );
    }
    undef($status);
    undef($errors);

    my $MIMELiteObj;
    my $md5; 
    my $mlo_status = 1; 
    my $mlo_errors = undef; 
   	
	
    if ( $draft_q->param('content_from') eq 'url' ) {

        # AWKWARD.
        # Redirect tag check
        my ( $rtc, $res, $md5 ) = grab_url({-url => $draft_q->param('plaintext_url') });
        my ( $status, $errors ) = $self->message_tag_check($rtc);
        if ( $status == 0 ) {
            return ( $status, $errors, undef, undef, undef );
        }
        undef($status);
        undef($errors);

        # Redirect tag check

        my $errors = undef;
        try { 
            ($mlo_status, $mlo_errors, $MIMELiteObj, $md5) 
				= $mailHTML->parse( $url, safely_encode($text_message) );
        } catch { 
            $errors .= "Problems with sending a webpage! Make sure you've correctly entered the URL to your webpage!\n";
            $errors .= "* Returned Error: $_";
            return ( 0, $errors, undef, undef, undef );  
        };
        if($mlo_status == 0){ 
            return ( 0, $mlo_errors, undef, undef, undef );  
        }
    }
    else {
		
        my $html_message; 
	    if ( $draft_q->param('content_from') eq 'none' ) {
			# ...
		}
		else {
	        $html_message = $draft_q->param('html_message_body');
	        ( $text_message, $html_message ) =
	          DADA::App::FormatMessages::pre_process_msg_strings( $text_message, $html_message );
		}
		
        my ( $status, $errors ) = $self->message_tag_check($html_message);
        if ( $status == 0 ) {
            return ( $status, $errors, undef, undef, undef );
        }
        undef($status);
        undef($errors);
		
        try { 
            ($mlo_status, $mlo_errors, $MIMELiteObj, $md5) 
				= $mailHTML->parse( safely_encode($html_message), safely_encode($text_message) ); 
        } catch { 
            my $errors = "Problems sending HTML! \n
            * Are you trying to send a webpage via URL instead?
            * Have you entered anything in the, HTML Version?
            * Returned Error: $_
            ";
            return ( 0, $errors, undef, undef, undef );
        }; 
        if($mlo_status == 0){ 
            return ( 0, $mlo_errors, undef, undef, undef );  
        }
    }

    my $fm = DADA::App::FormatMessages->new( -List => $self->{list} );
    $fm->mass_mailing(1);
    $fm->originating_message_url($url);
    $fm->Subject( $headers{Subject} );

    # This looks like it just checks for errors, with converting this to a string?
    # Alright.
    my $status           = 1;
    my $errors           = '';
    my $source           = '';
    my @MIME_HTML_errors = ();

    try { 
        $source = $MIMELiteObj->as_string; 
    } catch { 
        carp "$DADA::Config::PROGRAM_NAME $DADA::Config::VER - Send a Webpage isn't functioning correctly? - $_";
        $status           = 0;
        $errors           = $_;
        @MIME_HTML_errors = $mailHTML->errstr;
        for my $mhe (@MIME_HTML_errors) {
            $errors .= $mhe;
        }
        return ( 0, $errors, undef, undef, undef );
    };

    # / convert for string check.
    use MIME::Parser;
    my $parser = new MIME::Parser;
       $parser = optimize_mime_parser($parser);
    my $entity = $parser->parse_data($source);

    return ( 1, undef, $entity, $fm, $md5 );

}




sub subject_from_title_tag {

    my $self    = shift;
    my $draft_q = shift;
    my $html;

    if ( $draft_q->param('content_from') eq 'url' ) {
        my ( $src, $res, $md5 ) = grab_url({-url => $draft_q->param('url') });
        if ( $res->is_success ) {
            $html = $src;
        }
        else {
            carp 'couldn\'t fetch url: ' . $draft_q->param('url');
            return undef;
        }
    }
    else {
        $html = $draft_q->param('html_message_body');
    }
    try {
        
        require HTML::Element;
        require HTML::TreeBuilder;
        
        my $root = HTML::TreeBuilder->new(
            ignore_unknown      => 0,
            no_space_compacting => 1,
            store_comments      => 1,
        );
        
        $root->parse($html);
        $root->eof();
        $root->elementify();

        my $title_ele = $root->find_by_tag_name('title');
        return $title_ele->as_text;
    }
    catch {
        # aaaaaand if that does work, regex to the rescue!
        my ($title) = $html =~ m/<title>([a-zA-Z\/][^>]+)<\/title>/si;
        if ( defined($title) ) {
            return $title;
        }
        else {
            return undef;
        }
    };
}




sub send_url_email {

    my $self = shift;
    my ($args) = @_;

    my $q          = $args->{-cgi_obj};
    my $root_login = $args->{-root_login};

    my $process            = xss_filter( strip( scalar $q->param('process') ) );
    my $flavor             = xss_filter( strip( scalar $q->param('flavor') ) );
    my $test_sent          = xss_filter( strip( scalar $q->param('test_sent') ) ) || 0;
    my $done               = xss_filter( strip( scalar $q->param('done') ) ) || 0;
    my $test_recipient     = $q->param('test_recipient');
    my $restore_from_draft = $q->param('restore_from_draft') || 'true';
    my $ses_params         = $self->ses_params;
    my $draft_role         = $q->param('draft_role') || 'draft';

    my $li = $self->{ls_obj}->get( -all_settings => 1 );
    
    my $can_use_mime_lite_html = 1;
    my $mime_lite_html_error   = undef;
    try {
        require DADA::App::MyMIMELiteHTML
    }
    catch {
        $can_use_mime_lite_html = 0;
    };

    my $can_use_lwp_simple = 0;
    my $lwp_simple_error   = undef;
    eval { require LWP::Simple };
    if ( !$@ ) {
        $can_use_lwp_simple = 1;
    }
    else {
        $lwp_simple_error = $@;
    }

    my $fields = [];
    my $naked_fields = $self->{lh_obj}->subscriber_fields( { -dotted => 0 } );

    # Extra, special one...
    push( @$fields, { name => 'subscriber.email' } );
    for my $field ( @{ $self->{lh_obj}->subscriber_fields( { -dotted => 1 } ) } ) {
        push( @$fields, { name => $field } );
    }
    my $undotted_fields = [];

    # Extra, special one...
    push( @$undotted_fields, { name => 'email', label => 'Email Address' } );
    require DADA::ProfileFieldsManager;
    my $pfm         = DADA::ProfileFieldsManager->new;
    my $fields_attr = $pfm->get_all_field_attributes;
    for my $undotted_field ( @{$naked_fields} ) {
        push(
            @$undotted_fields,
            {
                name  => $undotted_field,
                label => $fields_attr->{$undotted_field}->{label}
            }
        );
    }

    if ( !$process ) {
        my ( $num_list_mailouts, $num_total_mailouts, $active_mailouts, $mailout_will_be_queued ) =
          $self->mass_mailout_info;
        my $draft_id = $self->find_draft_id(
            {
                -screen  => 'send_url_email',
                -role    => $draft_role,
                -cgi_obj => $q,
            }
        );

        require DADA::Template::Widgets;
        my %wysiwyg_vars = DADA::Template::Widgets::make_wysiwyg_vars( $self->{list} );

        my $scrn = DADA::Template::Widgets::wrap_screen(
            {
                -screen         => 'send_url_email_screen.tmpl',
                -with           => 'admin',
                -wrapper_params => {
                    -Root_Login => $root_login,
                    -List       => $self->{list},
                },
                -expr => 1,
                -vars => {

                    screen => 'send_url_email',

                    draft_id           => $draft_id,
                    draft_role         => $draft_role,
                    restore_from_draft => $restore_from_draft,
                    done               => $done,

                    test_sent      => $test_sent,
                    test_recipient => $test_recipient,

                    can_use_mime_lite_html     => $can_use_mime_lite_html,
                    mime_lite_html_error       => $mime_lite_html_error,
                    can_use_lwp_simple         => $can_use_lwp_simple,
                    lwp_simple_error           => $lwp_simple_error,
                    can_display_attachments    => $self->{ah_obj}->can_display_attachments,
                    fields                     => $fields,
                    undotted_fields            => $undotted_fields,
                    can_have_subscriber_fields => $self->{lh_obj}->can_have_subscriber_fields,
                    SERVER_ADMIN               => $ENV{SERVER_ADMIN},
                    priority_popup_menu        => DADA::Template::Widgets::priority_popup_menu( $self->{ls_obj}->get ),

                    MAILOUT_AT_ONCE_LIMIT  => $DADA::Config::MAILOUT_AT_ONCE_LIMIT,
                    mailout_will_be_queued => $mailout_will_be_queued,
                    num_list_mailouts      => $num_list_mailouts,
                    num_total_mailouts     => $num_total_mailouts,
                    active_mailouts        => $active_mailouts,
                    
                    schedule_last_checked_frt =>
                    formatted_runtime( time - $self->{ls_obj}->param('schedule_last_checked_time') ),
                    can_use_datetime  => scalar DADA::App::Guts::can_use_datetime(), 
                    can_use_HTML_Tree => scalar DADA::App::Guts::can_use_HTML_Tree(), 
                    sched_flavor      => $DADA::Config::SCHEDULED_JOBS_OPTIONS->{scheduled_jobs_flavor},


                    %wysiwyg_vars,
                    %$ses_params,

                },
                -list_settings_vars       => $li,
                -list_settings_vars_param => { -dot_it => 1, },
            }
        );
        if ( $restore_from_draft eq 'true' ) {
            $scrn = $self->fill_in_draft_msg(
                {
                    -screen   => 'send_url_email',
                    -str      => $scrn,
                    -draft_id => $draft_id,
                    -role     => $draft_role,
                }
            );
        }
        return ( {}, $scrn );

    }
    elsif ( $process eq 'save_as_draft' ) {
        my ( $headers, $body ) = $self->save_as_draft(
            {
                -cgi_obj => $q,
                -list    => $self->{list},
                -json    => 1,
            }
        );
        return ( $headers, $body );
    }
    else {

        # Draft now has all our form params
        # draft_id and role will be saved in $q
        my $draft_id = $self->save_as_draft(
            {
                -cgi_obj => $q,
                -list    => $self->{list},
                -json    => 0,
            }
        );
        # to fetch a draft, I need id, list and role (lame)
        my ( $status, $errors, $message_id, $md5 ) = $self->construct_and_send(
            {
                -draft_id => $draft_id,
                -screen   => 'send_url_email',
                -role     => $draft_role,
                -process  => $process,
            }
        );

        if ( $status == 0 ) {
            return $self->report_mass_mail_errors( $errors, $root_login );
        }
        if ( $process =~ m/test/i ) {
            $self->wait_for_it($message_id);
            return (
                {
                        -redirect_uri => $DADA::Config::S_PROGRAM_URL
                      . '?flavor='
                      . $flavor
                      . '&test_sent=1&test_recipient='
                      . $q->param('test_recipient')
                      . '&draft_id='
                      . $q->param('draft_id')
                      . '&restore_from_draft='
                      . $q->param('restore_from_draft')
                      . '&draft_role='
                      . $q->param('draft_role')
                },
                undef
            );
        }
        else {
            if ( defined($draft_id) ) {
                $self->{md_obj}->remove($draft_id);
            }
            my $uri;
            if ( $q->param('archive_no_send') == 1 && $q->param('archive_message') == 1 ) {
                $uri = $DADA::Config::S_PROGRAM_URL . '?flavor=view_archive&id=' . $message_id;
            }
            else {
                $uri = $DADA::Config::S_PROGRAM_URL . '?flavor=sending_monitor&type=list&id=' . $message_id;
            }
            return ( { -redirect_uri => $uri }, undef );
        }
    }
}

sub find_draft_id {

    my $self = shift;
    my ($args) = @_;

    my $q = $args->{-cgi_obj};
    my $restore_from_draft = $q->param('restore_from_draft') || 'true';

    my $draft_id = undef;

    # Get $draft_id based on if an id is passed, and role:

    # $restore_from_draft defaults to, "true" if no param is passed.
    if (   $restore_from_draft ne 'true'
        && $self->{md_obj}->has_draft( { -screen => $args->{-screen}, -role => $args->{-role} } ) )
    {
         $draft_id = undef;
    }
    elsif ($restore_from_draft eq 'true'
        && $self->{md_obj}->has_draft( { -screen => $args->{-screen}, -role => 'draft' } )
        && $args->{-role} eq 'draft' )
    {    # so, only drafts (not stationery),
        if ( defined( $q->param('draft_id') ) ) {
            $draft_id = $q->param('draft_id');
        }
        else {
            $draft_id = $self->{md_obj}->latest_draft_id( { -screen => $args->{-screen}, -role => 'draft' } );
        }
    }
    elsif ($restore_from_draft eq 'true'
        && $self->{md_obj}->has_draft( { -screen => $args->{-screen}, -role => 'stationery' } )
        && $args->{-role} eq 'stationery' )
    {
        if ( defined( $q->param('draft_id') ) ) {
            $draft_id = $q->param('draft_id');
        }
        else {
            # $draft_id = $self->{md_obj}->latest_draft_id( { -screen => 'send_email', -role => 'draft' } );
            # we don't want to load up the most recent stationery, since that's not how stationery... works.
        }
    }
    elsif ($restore_from_draft eq 'true'
        && $self->{md_obj}->has_draft( { -screen => $args->{-screen}, -role => 'schedule' } )
        && $args->{-role} eq 'schedule' )
    {
        if ( defined( $q->param('draft_id') ) ) {
            $draft_id = $q->param('draft_id');
        }
        else {
            # we don't want to load up the most recent schedule, since that's not how schedules... work.
        }
    }


    #/ Get $draft_id based on if an id is passed, and role:
    return $draft_id;

}

sub delete_draft {
    my $self = shift;
    my $id   = shift;
    $self->{md_obj}->remove($id);
}

sub ses_params {

    my $self = shift;
    my ($args) = @_;

	my $can_use_Amazon_SES      = DADA::App::Guts::can_use_Amazon_SES();
	
    my $ses_params = {};
    if (
		$can_use_Amazon_SES 
		&& (
        $self->{ls_obj}->param('sending_method') eq 'amazon_ses'
        || (   $self->{ls_obj}->param('sending_method') eq 'smtp'
            && $self->{ls_obj}->param('smtp_server') =~ m/amazonaws\.com/ )
      )
	  )
    {
        $ses_params->{using_ses} = 1;
        require DADA::App::AmazonSES;
        my $ses = DADA::App::AmazonSES->new;
        $ses_params->{list_owner_ses_verified} = $ses->sender_verified( $self->{ls_obj}->param('list_owner_email') );
        $ses_params->{list_admin_ses_verified} = $ses->sender_verified( $self->{ls_obj}->param('admin_email') );
        $ses_params->{discussion_pop_ses_verified} =
          $ses->sender_verified( $self->{ls_obj}->param('discussion_pop_email') );
    }

    return $ses_params;
}

sub wait_for_it {

    warn 'wait_for_it'
      if $t;

    my $self       = shift;
    my $message_id = shift;

    warn '$message_id ' . $message_id
      if $t;

    if ( $message_id == 0 ) {
        return 0;
    }
    my $still_working = 1;
    my $tries         = 0;
    require DADA::Mail::MailOut;
  SENDING_CHECK: while ($still_working) {
        $tries++;
        if ( DADA::Mail::MailOut::mailout_exists( $self->{list}, $message_id, 'list' ) == 1 ) {
            sleep(3);
        }
        else {
            $still_working = 0;
            last SENDING_CHECK;
        }
        if ( $tries > 5 ) {
            last SENDING_CHECK;
        }
    }
    return 1;
}

sub save_as_draft {

    warn 'save_as_draft'
      if $t;

    my $self = shift;
    my ($args) = @_;
    if ( $t == 1 ) {
        #require Data::Dumper;
        #warn 'args:' . Data::Dumper::Dumper($args);
    }

    my $q = $args->{-cgi_obj};

    if ( !exists( $args->{-json} ) ) {
        $args->{-json} = 0;
    }

    my $draft_id        = $q->param('draft_id')        || undef;
    my $draft_role      = $q->param('draft_role')      || 'draft';
    my $save_draft_role = $q->param('save_draft_role') || 'draft';
    my $screen          = $q->param('flavor')          || 'send_email';
 
    # I wanna that we do it, here! 
 
    my $saved_draft_id = $self->{md_obj}->save(
        {
            -cgi_obj   => $q,
            -id        => $draft_id,
            -role      => $draft_role,
            -save_role => $save_draft_role, 
            -screen    => $screen,
        }
    );

    warn '$saved_draft_id: ' . $saved_draft_id
        if $t; 

    if ( $args->{-json} == 1 ) {
        require JSON;
        my $json    = JSON->new->allow_nonref;
        my $return  = { id => $saved_draft_id };
        my $headers = {
            '-Cache-Control' => 'no-cache, must-revalidate',
            -expires         => 'Mon, 26 Jul 1997 05:00:00 GMT',
            -type            => 'application/json',
        };
        my $body = $json->pretty->encode($return);
        if($t == 1){ 
            require Data::Dumper; 
            warn 'returning headers: ' . Data::Dumper::Dumper($headers); 
            warn 'returning body: ' . $body; 
        }
        return ( $headers, $body );
    }
    else {
        return $saved_draft_id;
    }
}

sub list_invite {

    my $self       = shift;
    my ($args)     = @_;
    my $q          = $args->{-cgi_obj};
    my $root_login = $args->{-root_login};

    my $process = xss_filter( strip( scalar $q->param('process') ) );
    my $flavor  = xss_filter( strip( scalar $q->param('flavor') ) );

    require DADA::MailingList::Settings;
    my $ls = DADA::MailingList::Settings->new( { -list => $self->{list} } );
    my $li = $ls->get;

    require DADA::App::FormatMessages;
    my $fm = DADA::App::FormatMessages->new( -List => $self->{list} );

    if ( $process =~ m/send invitation\.\.\./i )
    {    # $process is dependent on the label of the button - which is not a good idea

        my ( $num_list_mailouts, $num_total_mailouts, $active_mailouts, $mailout_will_be_queued ) =
          $self->mass_mailout_info;

        my $field_names       = [];
        my $subscriber_fields = $self->{lh_obj}->subscriber_fields;
        for (@$subscriber_fields) {
            push( @$field_names, { name => $_ } );
        }

        my @addresses = $q->multi_param('address');

        my $verified_addresses        = [];
        my $invited_already_addresses = [];

        # Addresses hold CSV info - each item in the array is one line of CSV...

        for my $a (@addresses) {
            my $pre_info = $self->{lh_obj}->csv_to_cds($a);
            my $info     = {};

            # DEV: Here I got again:
            $info->{email} = $pre_info->{email};

            my $new_fields = [];
            my $i          = 0;
            for (@$subscriber_fields) {
                push( @$new_fields, { name => $_, value => $pre_info->{fields}->{$_} } );
                $i++;    # and then, $i is never used, again?
            }

            $info->{fields} = $new_fields;

            #And... Then this!
            $info->{csv_info} = $a;
            $info->{'list_settings.invites_prohibit_reinvites'} = $ls->param('invites_prohibit_reinvites');
            if ( $ls->param('invites_check_for_already_invited') == 1 ) {

                # invited, already?
                if (
                    $self->{lh_obj}->check_for_double_email(
                        -Email => $info->{email},
                        -Type  => 'invited_list'
                    ) == 1
                  )
                {
                    push( @$invited_already_addresses, $info );
                }
                else {
                    push( @$verified_addresses, $info );
                }
            }
            else {
                push( @$verified_addresses, $info );
            }
        }

        require DADA::Template::Widgets;
        my $scrn = DADA::Template::Widgets::wrap_screen(
            {
                -screen         => 'list_invite_screen.tmpl',
                -with           => 'admin',
                -wrapper_params => {
                    -Root_Login => $root_login,
                    -List       => $self->{list},
                },
                -expr => 1,
                -vars => {
                    using_no_wysiwyg_editor => 1,

                    screen => 'add',
                    list_type_isa_list =>
                      1,    # I think this only works with Subscribers at the moment, so no need to do a harder check...
                            # This is sort of weird, as it default to the "Send a Message" Subject
                    mass_mailing_type => 'invite',
                    Subject           => $ls->param('invite_message_subject'),
                    field_names       => $field_names,

                    verified_addresses        => $verified_addresses,
                    invited_already_addresses => $invited_already_addresses,

                    html_message_body_content            => $li->{invite_message_html},
                    html_message_body_content_js_escaped => js_enc( $li->{invite_message_html} ),
                    MAILOUT_AT_ONCE_LIMIT                => $DADA::Config::MAILOUT_AT_ONCE_LIMIT,
                    mailout_will_be_queued               => $mailout_will_be_queued,
                    num_list_mailouts                    => $num_list_mailouts,
                    num_total_mailouts                   => $num_total_mailouts,
                    active_mailouts                      => $active_mailouts,

                    using_no_wysiwyg_editor => 1,
                },
                -list_settings_vars       => $li,
                -list_settings_vars_param => { -dot_it => 1, },
            }
        );
        return ( {}, $scrn );

    }
    elsif (
        $process =~ m/send test invitation|send a test invitation|send invitations|send\: invit|send\: test invit/i )
    {    # $process is dependent on the label of the button - which is not a good idea

        my @address                 = $q->multi_param('address');
        my @already_invited_address = $q->multi_param('already_invited_address');

        # This is a little safety - there shouldn't be anything in
        # @already_invited_address anyways.
        if ( $ls->param('invites_prohibit_reinvites') != 1 ) {
            @address = ( @address, @already_invited_address );
        }

        for my $a (@address) {
            my $info = $self->{lh_obj}->csv_to_cds($a);
            $self->{lh_obj}->add_subscriber(
                {
                    -email => $info->{email},

                    # -fields => $info->{fields},
                    -type => 'invitelist',
                }
            );

            # There's a good reason we're not passing anything in -fields... right?
            $self->{lh_obj}->add_subscriber(
                {
                    -email => $info->{email},

                    # -fields     => $info->{fields},
                    -type       => 'sub_confirm_list',
                    -dupe_check => {
                        -enable  => 1,
                        -on_dupe => 'ignore_add',
                    },
                }
            );

            # Should this happen for TESTS as well?!
            $self->{lh_obj}->add_subscriber(
                {
                    -email      => $info->{email},
                    -fields     => $info->{fields},
                    -type       => 'invited_list',
                    -dupe_check => {
                        -enable  => 1,
                        -on_dupe => 'ignore_add',
                    },
                }
            );

        }

        # DEV: Headers.  Ugh, remember this is in, "Send a Webpage" as well.
        my %headers = ();
        for my $h (
            qw(
            Reply-To
            Return-Path
            X-Priority
            Subject
            )
          )
        {

            if ( defined( $q->param($h) ) ) {
                if ( $h eq 'Subject' ) {
                    $headers{$h} = $fm->_encode_header( 'Subject', $q->param($h) );
                }
                else {
                    $headers{$h} = strip( scalar $q->param($h) );
                }
            }
        }

        #/Headers

        my $text_message_body = $q->param('text_message_body') || undef;
        if ( $q->param('use_text_message') != 1 ) {
            $text_message_body = undef;
        }
        my $html_message_body = $q->param('html_message_body') || undef;
        if ( $q->param('use_html_message') != 1 ) {
            $html_message_body = undef;
        }

        if ( $text_message_body eq undef && $html_message_body eq undef ) {
            return $self->report_mass_mail_errors( "Message will be sent blank! Stopping!", $root_login );
        }

        ( $text_message_body, $html_message_body ) =
          DADA::App::FormatMessages::pre_process_msg_strings( $text_message_body, $html_message_body );

        require MIME::Entity;
        my $entity;

        if ( $text_message_body and $html_message_body ) {

            $text_message_body = safely_encode($text_message_body);
            $html_message_body = safely_encode($html_message_body);

            my ( $status, $errors ) = $self->message_tag_check($text_message_body);
            if ( $status == 0 ) {
                return $self->report_mass_mail_errors( $errors, $root_login );
            }
            undef($status);
            undef($errors);

            my ( $status, $errors ) = $self->message_tag_check($html_message_body);
            if ( $status == 0 ) {
                return $self->report_mass_mail_errors( $errors, $root_login );
            }
            undef($status);
            undef($errors);

            $entity = MIME::Entity->build(
                Type    => 'multipart/alternative',
                Charset => $li->{charset_value},
                %headers,
            );
            $entity->attach(
                Type     => 'text/plain',
                Data     => $text_message_body,
                Encoding => $li->{plaintext_encoding},
                Charset  => $li->{charset_value},
            );
            $entity->attach(
                Type     => 'text/html',
                Data     => $html_message_body,
                Encoding => $li->{html_encoding},
                Charset  => $li->{charset_value},
            );
        }
        elsif ($html_message_body) {

            $html_message_body = safely_encode($html_message_body);

            my ( $status, $errors ) = $self->message_tag_check($html_message_body);
            if ( $status == 0 ) {
                return $self->report_mass_mail_errors( $errors, $root_login );
            }
            undef($status);
            undef($errors);

            $entity = MIME::Entity->build(
                Type     => 'text/html',
                Data     => $html_message_body,
                Encoding => $li->{html_encoding},
                Charset  => $li->{charset_value},
                %headers,
            );
        }
        elsif ($text_message_body) {
            $text_message_body = safely_encode($text_message_body);

            my ( $status, $errors ) = $self->message_tag_check($text_message_body);
            if ( $status == 0 ) {
                return $self->report_mass_mail_errors( $errors, $root_login );
            }
            undef($status);
            undef($errors);

            $entity = MIME::Entity->build(
                Type     => 'text/plain',
                Data     => $text_message_body,
                Encoding => $li->{plaintext_encoding},
                Charset  => $li->{charset_value},
                %headers,
            );
        }
        else {

            warn
"$DADA::Config::PROGRAM_NAME $DADA::Config::VER warning: both text and html versions of invitation message blank?!";

            my ( $status, $errors ) = $self->message_tag_check( $ls->param('invite_message_text') );
            if ( $status == 0 ) {
                return $self->report_mass_mail_errors( $errors, $root_login );
            }
            undef($status);
            undef($errors);

            $entity = MIME::Entity->build(
                Type     => 'text/plain',
                Data     => safely_encode( $ls->param('invite_message_text') ),
                Encoding => $li->{plaintext_encoding},
                Charset  => $li->{charset_value},
                %headers,
            );

        }

        my $msg_as_string = ( defined($entity) ) ? $entity->as_string : undef;
        $msg_as_string = safely_encode($msg_as_string);
        $fm->Subject( $headers{Subject} );
        $fm->mass_mailing(1);
        $fm->use_email_templates(0);
        $fm->list_type('invitelist');
        my ( $header_glob, $message_string );
        eval { ( $header_glob, $message_string ) = $fm->format_headers_and_body( -msg => $msg_as_string ); };

        if ($@) {
            return $self->report_mass_mail_errors( $@, $root_login );
        }

        require DADA::Mail::Send;
        my $mh = DADA::Mail::Send->new(
            {
                -list   => $self->{list},
                -ls_obj => $ls,
            }
        );
        if ( exists( $args->{-Ext_Request} ) ) {
            $mh->Ext_Request( $args->{-Ext_Request} );
        }

        # translate the glob into a hash

        $mh->list_type('invitelist');

        $mh->mass_test(1)
          if ( $process =~ m/test/i );

        my $test_recipient = '';
        if ( $process =~ m/test/i ) {
            $mh->mass_test_recipient( strip( scalar $q->param('test_recipient') ) );
            $test_recipient = $mh->mass_test_recipient;
        }
        my $message_id = $mh->mass_send( $mh->return_headers($header_glob), Body => $message_string, );
        my $uri = $DADA::Config::S_PROGRAM_URL . '?flavor=sending_monitor&type=invitelist&id=' . $message_id;
        return ( { -redirect_uri => $uri }, undef );

    }
    else {
        die "unknown process type: " . $process;
    }
}

sub q_obj_from_draft {

    warn 'q_obj_from_draft'
      if $t;

    my $self = shift;
    my ($args) = @_;

    #if ( $t == 1 ) {
    #    require Data::Dumper;
    #    warn 'args:' . Data::Dumper::Dumper($args);
    #}

    for ( '-screen', '-draft_id', '-role' ) {
        if ( !exists( $args->{$_} ) ) {
            croak "You MUST pass the, '$_' parameter!";
        }
    }

    if (
        $self->{md_obj}->has_draft(
            {
                -screen => $args->{-screen},
                -role   => $args->{-role},
            }
        )
      )
    {
        warn 'has draft'
          if $t;

        my $q_draft = $self->{md_obj}->fetch(
            {
                -id     => $args->{-draft_id},
                -screen => $args->{-screen},
                -role   => $args->{-role},
            }
        );
        return $q_draft;
    }
    else {
        warn 'doesn\'t have a draft!';
        return undef;
    }
}

sub fill_in_draft_msg {

    my $self = shift;
    my ($args) = @_;

    for ('-str') {
        if ( !exists( $args->{$_} ) ) {
            croak "You MUST pass the, '$_' parameter!";
        }
    }

    my $q_draft = $self->q_obj_from_draft($args);
    my $str;

    if ( defined($q_draft) ) {
        require HTML::FillInForm::Lite;
        my $h       = HTML::FillInForm::Lite->new;
        my $tmp_str = $args->{-str};
        $str = $h->fill( 
            \$tmp_str, 
            $q_draft, 
            fill_password => 1,
#            ignore_fields => ['schedule_type'], # I can't get this to work. Ugh!
           # clear_absent_checkboxes => 1,
             );
        return $str;
    }
    else {
        return $args->{-str};
    }
}

sub draft_message_values {
    my $self = shift;
    my ($args) = @_;
    my $q = $args->{-cgi_obj}; 
    
    my $q_draft = $self->q_obj_from_draft(
        {
            -screen   => $q->param('draft_screen'), 
            -draft_id => $q->param('draft_id'), 
            -role     => $q->param('draft_role'), 
        }
    );
    
    # For now, I'm just sending back what I need: 
    my $hr = { 
        schedule_html_body_checksum => $q_draft->param('schedule_html_body_checksum'),
        schedule_activated          => $q_draft->param('schedule_activated'),
    };
    
    require JSON;
    my $json    = JSON->new->allow_nonref;
    my $headers = {
        '-Cache-Control' => 'no-cache, must-revalidate',
        -expires         => 'Mon, 26 Jul 1997 05:00:00 GMT',
        -type            => 'application/json',
    };
    my $body = $json->pretty->encode($hr);
    return ( $headers, $body );    
}


sub has_attachments {

    my $self = shift;

    my ($args) = @_;
    my $q = $args->{-cgi_obj};

    my $filemanager;
    if ( $DADA::Config::FILE_BROWSER_OPTIONS->{kcfinder}->{enabled} == 1 ) {
        $filemanager = 'kcfinder';
    }
    elsif ( $DADA::Config::FILE_BROWSER_OPTIONS->{core5_filemanager}->{enabled} == 1 ) {
        $filemanager = 'core5_filemanager';
    }

    my @ive_got = ();

    my $num = 5;

    for ( 1 .. $num ) {
        my $filename = $q->param( 'attachment' . $_ );
        warn '$filename:' . $filename
          if $t;

		# I shouldn't have to do this: 
		$filename =~ s/dada_mail_support_files\/file_uploads\///;
          
        if ( defined($filename) && length($filename) > 1 ) {
            if ( $filename ne 'Select A File...' && length($filename) > 0 ) {
                warn 'I\'ve got, ' . 'attachment' . $_
                  if $t;
				
				
				if ( !-e $DADA::Config::FILE_BROWSER_OPTIONS->{$filemanager}->{upload_dir} . '/' . $filename ) {
                    my $new_filename = uriunescape($filename);
                    if ( !-e $DADA::Config::FILE_BROWSER_OPTIONS->{$filemanager}->{upload_dir} . '/' . $new_filename ) {
                        warn "I can't find attachment file: "
                          . $DADA::Config::FILE_BROWSER_OPTIONS->{$filemanager}->{upload_dir} . '/'
                          . $filename;
                    }
                    else {
                        push( @ive_got, $new_filename );
                    }
                }
                else {
                    push( @ive_got, $filename );
                }
            }
        }
    }
    return @ive_got;
}

sub make_attachment {

    require MIME::Entity;

    my $self   = shift;
    my ($args) = @_;
    my $name   = $args->{-name};

    my $filemanager;
    if ( $DADA::Config::FILE_BROWSER_OPTIONS->{kcfinder}->{enabled} == 1 ) {
        $filemanager = 'kcfinder';
    }
    elsif ( $DADA::Config::FILE_BROWSER_OPTIONS->{core5_filemanager}->{enabled} == 1 ) {
        $filemanager = 'core5_filemanager';
    }

    if ( !$name ) {
        warn '!$name';
        return undef;
    }

    warn '$name:: ' . $name
      if $t;

    my $filename = $name;
    $filename =~ s/(.*?)\///;

    warn '$filename: ' . $filename
      if $t;

    my $a_type = $self->find_attachment_type($filename);

    warn '$a_type: ' . $a_type
      if $t;

    $filename =~ s!^.*(\\|\/)!!;
    $filename =~ s/\s/%20/g;

    my %mime_args = (
        Type        => $a_type,
        Disposition => $self->make_a_disposition($a_type),

        #  Datestamp         => 0,
        Id                 => $filename,
        Filename           => $filename,
        'Content-Location' => $filename,
        Path               => $DADA::Config::FILE_BROWSER_OPTIONS->{$filemanager}->{upload_dir} . '/' . $name,
    );

    if ($t) {
        require Data::Dumper;
        warn '%mime_args' . Data::Dumper::Dumper( {%mime_args} );
    }

    # warn 'building at make_attachment - start';
    my $entity = MIME::Entity->build(%mime_args);

    # warn 'building at make_attachment - done';

    # warn 'returning!';
    return $entity;

}

sub make_a_disposition {

    my $self        = shift;
    my $n           = shift;
    my $disposition = 'inline';

    if ( $n !~ m/image/ ) {

        #if($n !~ /text/){ # if they're inline, they get parsed as if
        # they were a part of Dada Mail... hmm...
        $disposition = 'attachment';

        #}
    }

    return $disposition;

}

sub find_attachment_type {

    my $self = shift;

    my $filename = shift;
    my $a_type;

    my $attach_name = $filename;
    $attach_name =~ s!^.*(\\|\/)!!;
    $attach_name =~ s/\s/%20/g;

    my $file_ending = $attach_name;
    $file_ending =~ s/.*\.//;

    require MIME::Types;
    require MIME::Type;

    if ( ( $MIME::Types::VERSION >= 1.005 ) && ( $MIME::Type::VERSION >= 1.005 ) ) {
        my ( $mimetype, $encoding ) = MIME::Types::by_suffix($filename);
        $a_type = $mimetype
          if ( $mimetype && $mimetype =~ /^\S+\/\S+$/ );    ### sanity check
    }
    else {
        if ( exists( $DADA::Config::MIME_TYPES{ '.' . lc($file_ending) } ) ) {
            $a_type = $DADA::Config::MIME_TYPES{ '.' . lc($file_ending) };
        }
        else {
            $a_type = $DADA::Config::DEFAULT_MIME_TYPE;
        }
    }
    if ( !$a_type ) {
        warn "attachment MIME Type never figured out, letting MIME::Entity handle this...";
        $a_type = 'AUTO';
    }

    return $a_type;
}

sub datetime_to_ctime {
    my $self     = shift;
    my $datetime = shift;

    require Time::Local;
    my ( $date, $time ) = split( ' ', $datetime );
    my ( $year, $month,  $day )    = split( '-', $date );
    my ( $hour, $minute, $second ) = split( ':', $time );
    $second = int( $second - 0.5 );    # no idea.
    my $time = Time::Local::timelocal( $second, $minute, $hour, $day, $month - 1, $year );

    return $time;
}

sub datetime_to_localtime {
    my $self     = shift;
    my $datetime = shift;
    my $time     = $self->datetime_to_ctime($datetime);
    return scalar( localtime($time) );
}

sub backdated_msg_id {

    my $self     = shift;
    my $datetime = shift;
    my $time     = $self->datetime_to_ctime($datetime);
    my ( $sec, $min, $hour, $day, $month, $year ) = ( localtime($time) )[ 0, 1, 2, 3, 4, 5 ];
    my $message_id = sprintf( "%02d%02d%02d%02d%02d%02d", $year + 1900, $month + 1, $day, $hour, $min, $sec );
    return $message_id;

}

sub mass_mailout_info {

    my $self = shift;

    my $num_list_mailouts      = undef;
    my $num_total_mailouts     = undef;
    my $mailout_will_be_queued = undef;

    my (
        $monitor_mailout_report, $total_mailouts,  $active_mailouts,
        $paused_mailouts,        $queued_mailouts, $inactive_mailouts
    );

    eval {
        require DADA::Mail::MailOut;

        my @mailouts = DADA::Mail::MailOut::current_mailouts( { -list => $self->{list} } );
        $num_list_mailouts = $#mailouts + 1;

        (
            $monitor_mailout_report, $total_mailouts,  $active_mailouts,
            $paused_mailouts,        $queued_mailouts, $inactive_mailouts
          )
          = DADA::Mail::MailOut::monitor_mailout(
            {
                -verbose => 0,
                -list    => $self->{list},
                -action  => 0,
            }
          );
        $num_total_mailouts = $total_mailouts;
    };
    if ($@) {
        warn
"Problems filling out the 'Sending Monitor' admin menu item with interesting bits of information about the mailouts: $@";
    }
    else {

        if ( $DADA::Config::MAILOUT_AT_ONCE_LIMIT ne undef ) {
            if ( $active_mailouts >= $DADA::Config::MAILOUT_AT_ONCE_LIMIT ) {
                $mailout_will_be_queued = 1;
            }
        }
    }
    return ( $num_list_mailouts, $num_total_mailouts, $active_mailouts, $mailout_will_be_queued );
}

sub message_tag_check { 
    my $self   = shift;
    my $str    = shift; 
	
    my ($status, $errors) = $self->valid_template_markup_check($str); 
	if($status == 0){ 
		return (0, $errors);
	}

    ($status, $errors) = $self->redirect_tag_check($str); 
	if($status == 0){ 
		return (0, $errors);
	}
	else { 
		return (1, undef);
	}
	
}

sub valid_template_markup_check { 
    my $self   = shift;
	my $str    = shift; 
	my $expr   = shift || 1; # probably just going to be 1...
	my $error_str = undef; 
	
	require DADA::Template::Widgets;
    my ( $valid, $errors ) = DADA::Template::Widgets::validate_screen(
        {
            -data => \$str,
            -expr => $expr,
        }
    );
    if ( $valid == 0 ) {
        my $munge = quotemeta('/fake/path/for/non/file/template');
        $errors =~ s/$munge/line/;
        $error_str = $errors . "\n"
          . '-' x 72 . "\n"
          . $str;
    	  return (0, $errors);
	}
	
	undef $valid; 
	undef $errors; 
	
	my $new_data; 
	try {
		require DADA::App::FormatMessages::Filters::UnescapeTemplateTags; 
		my $utt = DADA::App::FormatMessages::Filters::UnescapeTemplateTags->new; 
		$new_data = $utt->filter({-html_msg => $str});
	} catch {
		 return (0, $_);
	};
	require DADA::Template::Widgets;
    my ( $valid, $errors ) = DADA::Template::Widgets::validate_screen(
        {
            -data => \$new_data,
            -expr => $expr,
        }
    );
    if ( $valid == 0 ) {
        my $munge = quotemeta('/fake/path/for/non/file/template');
        $errors =~ s/$munge/line/;
        $error_str = $errors . "\n"
          . '-' x 72 . "\n"
          . $str;
    	  return (0, $errors);
	}
	
	# Or, everything is cool, 
	return (1, undef)
	
	
}
sub redirect_tag_check {

    my $self   = shift;
	my $str    = shift; 
	
    my $errors = undef;
	
    require DADA::MailingList::Settings;
    my $ls = DADA::MailingList::Settings->new( { -list => $self->{list} } );
    require DADA::Logging::Clickthrough;
    my $ct = DADA::Logging::Clickthrough->new(
        {
            -list => $self->{list},
            -ls   => $ls,
        }
    );
    try { 
		$ct->check_redirect_urls( { -str => $str, -raise_error => 1, } );
	} catch {
        return ( 0, $_ );
    };
	
    return ( 1, undef );
 
}

sub report_mass_mail_errors {

    my $self       = shift;
    my $errors     = shift;
    my $root_login = shift;

    require DADA::Template::Widgets;
    my $scrn = DADA::Template::Widgets::wrap_screen(
        {
            -with           => 'admin',
            -wrapper_params => {
                -Root_Login => $root_login,
                -List       => $self->{list},
            },
            -screen => 'report_mass_mailing_errors_screen.tmpl',
            -vars   => { errors => $errors }
        }
    );
    return ( {}, $scrn );
}

sub just_subscribed_mass_mailing {

    my $self = shift;

    my ($args) = @_;
    if ( !$args->{-addresses}->[0] ) {
        return;
    }

    my $type = '_tmp-just_subscribed-' . time;

    for my $info ( @{ $args->{-addresses} } ) {
        my $dmls = $self->{lh_obj}->add_subscriber(
            {
                -email      => $info->{email},
                -type       => $type,
                -dupe_check => {
                    -enable  => 1,
                    -on_dupe => 'ignore_add',
                },
            }
        );
    }

    require DADA::App::FormatMessages;
    my $fm = DADA::App::FormatMessages->new( -List => $self->{list} );
    $fm->mass_mailing(1);
    $fm->list_type('just_subscribed');
    $fm->use_email_templates(0);

    require DADA::MailingList::Settings;
    my $ls = DADA::MailingList::Settings->new( { -list => $self->{list} } );
    my ( $header_glob, $message_string ) = $fm->format_headers_and_body(
        -msg => $fm->string_from_dada_style_args(
            {
                -fields => {
                    Subject => $ls->param('subscribed_by_list_owner_message_subject'),
                    Body    => $ls->param('subscribed_by_list_owner_message'),
                },
            }
        )
    );

    require DADA::Mail::Send;
    my $mh = DADA::Mail::Send->new( { -list => $self->{list} } );
    $mh->list_type($type);
    my $message_id = $mh->mass_send( { -msg => { $mh->return_headers($header_glob), Body => $message_string, }, } );
    return 1;

}

sub just_unsubscribed_mass_mailing {

    my $self = shift;
    my ($args) = @_;

    if($t){ 
        warn 'just_unsubscribed_mass_mailing'; 
        require Data::Dumper; 
        warn '$args:' . Data::Dumper::Dumper($args); 
    }
    
        
    my $type = '_tmp-just_unsubscribed-' . time;
    if ( ! $args->{-addresses}->[0] ) {
        if ( exists( $args->{-send_to_everybody} ) ) {
            $self->{lh_obj}->clone(
                {
                    -from => 'list',
                    -to   => $type,
                }
            );
        }
        else {
            return;
        }
    }
    else {
        for my $a ( @{ $args->{-addresses} } ) {
            my $dmls = $self->{lh_obj}->add_subscriber(
                {
                    -email      => $a,
                    -type       => $type,
                    -dupe_check => {
                        -enable  => 1,
                        -on_dupe => 'ignore_add',
                    },
                }
            );
        }
    }

    require DADA::App::FormatMessages;
    my $fm = DADA::App::FormatMessages->new( -List => $self->{list} );
    $fm->use_email_templates(0);
    $fm->mass_mailing(1);
    $fm->list_type('just_unsubscribed');

    require DADA::MailingList::Settings;
    my $ls = DADA::MailingList::Settings->new( { -list => $self->{list} } );
    my ( $header_glob, $message_string ) = $fm->format_headers_and_body(
        -msg => $fm->string_from_dada_style_args(
            {
                -fields => {
                    Subject => $ls->param('unsubscribed_by_list_owner_message_subject'),
                    Body    => $ls->param('unsubscribed_by_list_owner_message'),
                },
            }
        )
    );

    require DADA::Mail::Send;
    my $mh = DADA::Mail::Send->new( { -list => $self->{list} } );
    $mh->list_type($type);
    my $message_id = $mh->mass_send( { -msg => { $mh->return_headers($header_glob), Body => $message_string, }, } );
    return 1;
}

sub send_last_archived_msg_mass_mailing {

    my $self = shift;
    my ($args) = @_;
    if ( !$args->{-addresses}->[0] ) {
        warn 'no subscribers passed.';
        return;
    }

    require DADA::MailingList::Archives;
    my $la = DADA::MailingList::Archives->new( { -list => $self->{list} } );
    my $entries = $la->get_archive_entries();
    if ( scalar(@$entries) <= 0 ) {
        return;
    }

    # Subscribe 'em

    my $type = '_tmp-just_subed_archive-' . time;

    for my $info ( @{ $args->{-addresses} } ) {
        my $dmls = $self->{lh_obj}->add_subscriber(
            {
                -email      => $info->{email},
                -type       => $type,
                -dupe_check => {
                    -enable  => 1,
                    -on_dupe => 'ignore_add',
                },
            }
        );
    }

    my $newest_entry = $la->newest_entry;

    my ( $head, $body ) = $la->massage_msg_for_resending(
        -key     => $newest_entry,
        '-split' => 1,
    );

    require DADA::Mail::Send;
    my $mh = DADA::Mail::Send->new( { -list => $self->{list} } );
    $mh->list_type($type);
    my $message_id = $mh->mass_send( { -msg => { $mh->return_headers($head), Body => $body, }, } );
    return 1;
}

sub DESTROY {

    my $self = shift;

}

1;

