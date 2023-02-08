# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::API::V1::Github;
use 5.10.1;
use Mojo::Base qw( Mojolicious::Controller );

use Bugzilla::Attachment;
use Bugzilla::Bug;
use Bugzilla::BugMail;
use Bugzilla::Constants;
use Bugzilla::Group;
use Bugzilla::User;

use Bugzilla::Extension::TrackingFlags::Flag;
use Bugzilla::Extension::TrackingFlags::Flag::Bug;

use Digest::SHA qw(hmac_sha256_hex);
use Mojo::Util  qw(secure_compare);

sub setup_routes {
  my ($class, $r) = @_;
  $r->post('/github/pull_request')->to('V1::Github#pull_request');
  $r->post('/github/push_comment')->to('V1::Github#push_comment');
}

sub pull_request {
  my ($self) = @_;
  my $template = Bugzilla->template;
  Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);

  # Return early if linking is not allowed
  return $self->code_error('github_pr_linking_disabled')
    if !Bugzilla->params->{github_pr_linking_enabled};

  # Return early if not a pull_request or ping event
  my $event = $self->req->headers->header('X-GitHub-Event');
  if (!$event || ($event ne 'pull_request' && $event ne 'ping')) {
    return $self->code_error('github_pr_not_pull_request');
  }

  # Verify that signature is correct based on shared secret
  if (!$self->verify_signature) {
    return $self->code_error('github_pr_mismatch_signatures');
  }

  # If event is a ping and we passed the signature check
  # then return success
  if ($event eq 'ping') {
    return $self->render(json => {error => 0});
  }

  # Parse pull request title for bug ID
  my $payload = $self->req->json;
  if ( !$payload
    || !$payload->{action}
    || !$payload->{pull_request}
    || !$payload->{pull_request}->{html_url}
    || !$payload->{pull_request}->{title}
    || !$payload->{pull_request}->{number}
    || !$payload->{repository}->{full_name})
  {
    return $self->code_error('github_pr_invalid_json');
  }

  # We are only interested in new pull request events
  # and not changes to existing ones (non-fatal).
  my $message;
  if ($payload->{action} ne 'opened') {
    $template->process('global/code-error.html.tmpl',
      {error => 'github_pr_invalid_event'}, \$message)
      || die $template->error();
    return $self->render(json => {error => 1, message => $message});
  }

  my $html_url   = $payload->{pull_request}->{html_url};
  my $title      = $payload->{pull_request}->{title};
  my $pr_number  = $payload->{pull_request}->{number};
  my $repository = $payload->{repository}->{full_name};

  # Find bug ID in the title and see if bug exists and client
  # can see it (non-fatal).
  my ($bug_id) = $title =~ /\b[Bb]ug[ -](\d+)\b/;
  my $bug      = Bugzilla::Bug->new($bug_id);
  if ($bug->{error}) {
    $template->process('global/code-error.html.tmpl',
      {error => 'github_pr_bug_not_found'}, \$message)
      || die $template->error();
    return $self->render(json => {error => 1, message => $message});
  }

  # Check if bug already has this pull request attached (non-fatal)
  foreach my $attachment (@{$bug->attachments}) {
    next if $attachment->contenttype ne 'text/x-github-pull-request';
    if ($attachment->data eq $html_url) {
      $template->process('global/code-error.html.tmpl',
        {error => 'github_pr_attachment_exists'}, \$message)
        || die $template->error();
      return $self->render(json => {error => 1, message => $message});
    }
  }

  # Create new attachment using pull request URL as attachment content
  my $auto_user = Bugzilla::User->check({name => 'automation@bmo.tld'});
  $auto_user->{groups}       = [Bugzilla::Group->get_all];
  $auto_user->{bless_groups} = [Bugzilla::Group->get_all];
  Bugzilla->set_user($auto_user);

  my $timestamp = Bugzilla->dbh->selectrow_array("SELECT NOW()");

  my $attachment = Bugzilla::Attachment->create({
    bug         => $bug,
    creation_ts => $timestamp,
    data        => $html_url,
    description => "[$repository] $title (#$pr_number)",
    filename    => "github-$pr_number-url.txt",
    ispatch     => 0,
    isprivate   => 0,
    mimetype    => 'text/x-github-pull-request',
  });

  # Insert a comment about the new attachment into the database.
  $bug->add_comment(
    '',
    {
      type        => CMT_ATTACHMENT_CREATED,
      extra_data  => $attachment->id,
      is_markdown => (Bugzilla->params->{use_markdown} ? 1 : 0)
    }
  );
  $bug->update($timestamp);

  # Fixup attachments with same github pull request but on different bugs
  my %other_bugs;
  my $other_attachments = Bugzilla::Attachment->match({
    mimetype => 'text/x-github-pull-request',
    filename => "github-$pr_number-url.txt",
    WHERE    => {'bug_id != ? AND NOT isobsolete' => $bug->id}
  });
  foreach my $attachment (@$other_attachments) {
    # same pr number but different repo so skip it
    next if $attachment->data ne $html_url;

    $other_bugs{$attachment->bug_id}++;
    my $moved_comment
      = "GitHub pull request attachment was moved to bug "
      . $bug->id
      . ". Setting attachment "
      . $attachment->id
      . " to obsolete.";
    $attachment->set_is_obsolete(1);
    $attachment->bug->add_comment(
      $moved_comment,
      {
        type        => CMT_ATTACHMENT_UPDATED,
        extra_data  => $attachment->id,
        is_markdown => (Bugzilla->params->{use_markdown} ? 1 : 0)
      }
    );
    $attachment->bug->update($timestamp);
    $attachment->update($timestamp);
  }

  # Return new attachment id when successful
  return $self->render(json => {error => 0, id => $attachment->id});
}

sub push_comment {
  my ($self) = @_;
  my $template = Bugzilla->template;
  Bugzilla->usage_mode(USAGE_MODE_MOJO_REST);

  # Return early if push commenting is not allowed
  return $self->code_error('github_push_comment_disabled')
    if !Bugzilla->params->{github_push_comment_enabled};

  # Return early if not a push or ping event
  my $event = $self->req->headers->header('X-GitHub-Event');
  if (!$event || ($event ne 'push' && $event ne 'ping')) {
    return $self->code_error('github_push_comment_not_push');
  }

  # Verify that signature is correct based on shared secret
  if (!$self->verify_signature) {
    return $self->code_error('github_push_comment_mismatch_signatures');
  }

  # If event is a ping and we passed the signature check
  # then return success
  if ($event eq 'ping') {
    return $self->render(json => {error => 0});
  }

  # Parse push commit title for bug ID
  my $payload = $self->req->json;
  if ( !$payload
    || !$payload->{ref}
    || !$payload->{pusher}
    || !$payload->{pusher}->{name}
    || !$payload->{commits})
  {
    return $self->code_error('github_push_comment_invalid_json');
  }

  my $pusher  = $payload->{pusher}->{name};
  my $ref     = $payload->{ref};
  my $commits = $payload->{commits};

  # Return success early if there are no commits or the ref is not a branch
  if (!@{$commits} || $ref !~ /refs\/heads\//) {
    return $self->render(json => {error => 0});
  }

  # Keep a list of bug ids that need to have comments added. 
  # We also use this for sending email later.
  # Use a hash so we don't have duplicates. If multiple commits
  # reference the same bug ID, then only one comment will be added
  # with the text combined.
  # When the comment is created, we will store the comment id to
  # return to the caller.
  my %update_bugs;

  # Create a separate comment for each commit
  foreach my $commit (@{$commits}) {
    my $message = $commit->{message};
    my $url     = $commit->{url};

    if (!$url || !$message) {
      return $self->code_error('github_pr_invalid_json');
    }

    # Find bug ID in the title and see if bug exists
    my ($bug_id) = $message =~ /\b[Bb]ug[ -](\d+)\b/;
    next if !$bug_id;

    my $comment_text = "Authored by https://github.com/$pusher\n$url\n$message";

    $update_bugs{$bug_id} ||= [];
    push @{$update_bugs{$bug_id}}, {text => $comment_text};
  }

  # If no bugs were found, then we return an error
  if (!keys %update_bugs) {
    return $self->code_error('github_push_comment_bug_not_found');
  }

  # Set current user to automation so we can add comments to private bugs
  my $auto_user = Bugzilla::User->check({name => 'automation@bmo.tld'});
  $auto_user->{groups}       = [Bugzilla::Group->get_all];
  $auto_user->{bless_groups} = [Bugzilla::Group->get_all];
  Bugzilla->set_user($auto_user);

  my $dbh = Bugzilla->dbh;
  $dbh->bz_start_transaction;

  # Actually create the comments in this loop
  foreach my $bug_id (keys %update_bugs) {
    my $bug = Bugzilla::Bug->new({id => $bug_id, cache => 1});
    next if $bug->{error};

    # Create a single comment if one or more commits reference the same bug
    my $comment_text;
    foreach my $comment (@{$update_bugs{$bug_id}}) {
      $comment_text .= $comment->{text} . "\n\n";
    }

    $bug->add_comment($comment_text);

    # If the bug does not have the keywork 'leave-open',
    # we can also close the bug as RESOLVED/FIXED.
    if (!$bug->has_keyword('leave-open')
      && $bug->status ne 'RESOLVED'
      && $bug->status ne 'VERIFIED')
    {
      # Set the bugs status to RESOLVED/FIXED
      $bug->set_bug_status('RESOLVED', {resolution => 'FIXED'});

      # Update the qe-verify flag if not set and the bug was closed.
      my $found_flag;
      foreach my $flag (@{$bug->flags}) {

        # Ignore for all flags except `qe-verify`.
        next if $flag->name ne 'qe-verify';
        $found_flag = 1;
        last;
      }

      if (!$found_flag) {
        my $qe_flag = Bugzilla::FlagType->new({name => 'qe-verify'});
        if ($qe_flag) {
          $bug->set_flags(
            [],
            [{
              flagtype => $qe_flag,
              setter   => Bugzilla->user,
              status   => '+',
              type_id  => $qe_flag->id,
            }]
          );
        }
      }

      # Update the status flag to 'fixed' if one exists for the current branch
      # Currently tailored for mozilla-mobile/firefox-android
      $ref =~ /refs\/heads\/releases_v(\d+)/;
      if (my $version = $1) {
        my $status_field = 'cf_status_firefox' . $version;
        my $flag
          = Bugzilla::Extension::TrackingFlags::Flag->new({name => $status_field});
        if ($flag && $bug->$status_field ne 'fixed') {
          foreach my $value (@{$flag->values}) {
            next if $value->value ne 'fixed';
            last if !$flag->can_set_value($value->value);

            Bugzilla::Extension::TrackingFlags::Flag::Bug->create({
              tracking_flag_id => $flag->flag_id,
              bug_id           => $bug->id,
              value            => $value->value,
            });

            # Add the name/value pair to the bug object
            $bug->{$flag->name} = $value->value;
            last;
          }
        }
      }
    }

    $bug->update();

    my $comments = $bug->comments({order => 'newest_to_oldest'});
    my $new_comment_id = $comments->[0]->id;

    $dbh->bz_commit_transaction;

    $update_bugs{$bug_id} = {id => $new_comment_id, text => $comment_text};

    # Send mail
    Bugzilla::BugMail::Send($bug_id, {changer => Bugzilla->user});
  }

  # Return comment id when successful
  return $self->render(json => {error => 0, bugs => \%update_bugs});
}

sub verify_signature {
  my ($self)             = @_;
  my $payload            = $self->req->body;
  my $secret             = Bugzilla->params->{github_pr_signature_secret};
  my $received_signature = $self->req->headers->header('X-Hub-Signature-256');
  my $expected_signature = 'sha256=' . hmac_sha256_hex($payload, $secret);
  return secure_compare($expected_signature, $received_signature) ? 1 : 0;
}

1;
