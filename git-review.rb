require 'rubygems'
require 'bundler/setup'

require 'grit'
require 'rest_client'
require 'json'

include Grit

@repo_location = "/the/actual/repo/location"
@repo_path = "git://the.repo.path.configured.in.reviewboard"
@reviewboard_url = "http://url.to.your.reviewboard.com"
@reviewboard_username = 'user'
@reviewboard_password = 'password'
# list of author emails and their corresponding username in reviewboard.
@authors = {
  "author@example.com" => "author",
  }

# monkey patch Tempfile to return "diff" as the original_filename
class Tempfile
  def original_filename
    "diff"
  end
end

def parse_author(author)
  @authors[author.email]
end

# read the parameters from stdin
stdins = []; stdins << $_ while gets

stdins.each do |str|
  arr = str.split
  refs = arr[2].split('/')

  @old_rev = arr[0]
  @new_rev = arr[1]
  @ref_type = refs[1]
  @ref_name = refs[2]
end

# we don't care about tags
exit unless @ref_type == "heads"

repo = Repo.new(@repo_location)
commit = repo.commit(@new_rev)
submit_as = parse_author(commit.author)
# if we don't know the author, we don't want to post a review. This is to support merges in the kernel trees for instance.
exit unless submit_as

# set up a resource
reviewboard = RestClient::Resource.new(@reviewboard_url, :user => @reviewboard_username, :password => @reviewboard_password, :headers => { :accept => 'application/json', :accept_encoding => ''})
api = reviewboard['api/']
review_requests = api['review-requests/']

# create a new review request
parsed = JSON.parse review_requests.post :multipart => true, :repository => @repo_path, :submit_as => submit_as
exit unless parsed["review_request"]["id"]

our_id = parsed["review_request"]["id"]
review = review_requests["#{our_id}/"]

review_draft = review['draft/']
# update the draft with the information on hand
parsed = JSON.parse review_draft.put :multipart => true, :target_groups => 'utvikling', :summary => commit.short_message, :description => commit.message
exit unless parsed["stat"] == "ok"

review_diffs = review['diffs/']
diff_file = Tempfile.new('diff')
begin
  commit.diffs.each do |diff|
    # recreate the "diff --git" output
    diff_file.write "diff --git #{diff.a_path} #{diff.b_path}\n"
    diff_file.write "index #{diff.a_blob.id}..#{diff.b_blob.id} #{diff.b_mode}\n"
    diff_file.write diff.diff
    diff_file.write "\n"
  end

  diff_file.rewind

  # use the file variant of the multipart class, since reviewboard did not work with just "path".
  parsed = JSON.parse review_diffs.post :multipart => true, "path" => diff_file
  exit unless parsed["stat"] == "ok"
ensure
  diff_file.close
  diff_file.unlink
end

# publish the review.
parsed = JSON.parse review_draft.put :multipart => true, :public => 1
exit unless parsed["stat"] == "ok"

p "Posted review #{our_id}."
