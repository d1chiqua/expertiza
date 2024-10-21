# TeamAssignmentService automates teams creation from user bids and assigns topics to them.
# It uses an external web service to get team information and handles matching teams with topics
# for an assignment.
#TODO - Add bidding in the name somehow - assign topic based on bids
class TeamAssignmentService
    require 'json'
    require 'rest_client'
    
    # Initializes the service with an assignment
    def initialize(assignment_id)
      @assignment = Assignment.find(assignment_id)
      @bidding_data = {}
      @teams_response = []
    end
  
    # The method intelligently assigns teams by generating bid data, fetching team info from a web service,
    # creating new teams with this data, removing empty teams, and matching them to topics
    #TODO - think of a better name
    def assign_teams_to_topics
      generate_bidding_data
      fetch_teams_data_from_web_service
      create_new_teams(@teams_response, @bidding_data[:users])
      @assignment.remove_empty_teams
      match_new_teams_to_topics(@assignment)
    rescue StandardError => e
      raise e
    end
  
    private
  
    # Creates the bidding data from users
    # TODO - compile_bidding_data - give more of an idea of what kind of data we're working with.
    def generate_bidding_data
      teams = assignment.teams
      users_bidding_info = construct_users_bidding_info(assignment.sign_up_topics, teams)
      @bidding_data = { users: users_bidding_info, max_team_size: assignment.max_team_size }
    end
  
    # Generate user bidding information hash based on students who haven't signed up yet
    # This associates a list of bids corresponding to sign_up_topics to a user
    # Structure of users_bidding_info variable: [{user_id1, bids_1}, {user_id2, bids_2}]
    def construct_users_bidding_info(sign_up_topics, teams)
      users_bidding_info = []
  
      # Retrieve IDs of teams that have already signed up (not waitlisted)
      signed_up_team_ids = SignedUpTeam.where(is_waitlisted: 0).pluck(:team_id).to_set
  
      # Exclude any teams already signed up
      teams_not_signed_up = teams.reject { |team| signed_up_team_ids.include?(team.id) }
  
      teams_not_signed_up.each do |team|
        # Grab student id and list of bids
        bids = []
        sign_up_topics.each do |topic|
          bid_record = Bid.find_by(team_id: team.id, topic_id: topic.id) #TODO: Is there a way to do this without loop? Use a single query
          bids << (bid_record.try(:priority) || 0)
        end
        team.users.each { |user| users_bidding_info << { pid: user.id, ranks: bids } } unless bids.uniq == [0]
      end
      users_bidding_info
    end
  
    # Fetches team data by calling an external web service that uses students' bidding data to build teams automatically.
    # The web service tries to create teams close to the assignment's maximum team size by combining smaller teams
    # with similar bidding priorities for the assignment's sign-up topics.  
    # TODO: simplify the name of the method 
    def fetch_teams_data_from_web_service
      url = WEBSERVICE_CONFIG['topic_bidding_webservice_url']
      response = RestClient.post url, bidding_data.to_json, content_type: :json, accept: :json
  
      # Structure of teams variable: [[user_id1, user_id2], [user_id3, user_id4]]
      @teams_response = JSON.parse(response)['teams']
    rescue RestClient::ExceptionWithResponse => e
      raise StandardError, "Failed to fetch teams from web service: #{e.response}"
    end
  
    # Creates new teams based on the response from the web service and the users' bidding data.
    def create_new_teams(teams_response, users_bidding_info) # TODO - look into if it is getting teams before assigning topics - making that better
      teams_response.each do |user_ids|
        new_team = AssignmentTeam.create_team_with_users(assignment.id, user_ids)
        # Select data from `users_bidding_info` variable that only related to team members in current team
        current_team_members_info = users_bidding_info.select { |info| user_ids.include? info[:pid] }.map { |info| info[:ranks] }
        Bid.merge_bids_from_different_users(new_team.id, assignment.sign_up_topics, current_team_members_info)
      end
    end
  
    # Pairs new teams with topics they've chosen based on bids.
    # This method is called for assignments which have their is_intelligent property set to 1.
    # It runs a stable match algorithm and assigns topics to strongest contenders (team strength, priority of bids).
    def match_new_teams_to_topics(assignment)
      unless assignment.is_intelligent
        raise StandardError, "This action is not allowed. The assignment #{@assignment.name} does not enable intelligent assignments."
      end
  
      sign_up_topics = SignUpTopic.where('assignment_id = ? AND max_choosers > 0', assignment.id)
      unassigned_teams = assignment.teams.reload.select do |t|
        SignedUpTeam.where(team_id: t.id, is_waitlisted: 0).blank? && Bid.where(team_id: t.id).any?
      end
      # Sorting unassigned_teams by team size desc, number of bids in current team asc
      # again, we need to find a way to to merge bids that came from different previous teams
      # then sorting unassigned_teams by number of bids in current team (less is better)
      # and we also need to think about, how to sort teams when they have the same team size and number of bids
      # maybe we can use timestamps in this case
      unassigned_teams.sort! do |t1, t2|
        [TeamsUser.where(team_id: t2.id).size, Bid.where(team_id: t1.id).size] <=>
          [TeamsUser.where(team_id: t1.id).size, Bid.where(team_id: t2.id).size]
      end
      teams_bidding_info = construct_teams_bidding_info(unassigned_teams, sign_up_topics)
      assign_available_slots(teams_bidding_info)
      # Remove is_intelligent property from assignment so that it can revert to the default sign-up state
      assignment.update(is_intelligent: false)
    end
  
    # Constructs bidding information for teams including their bids on available topics
    #TODO - make tables of bids might be clearer
    def construct_teams_bidding_info(unassigned_teams, sign_up_topics)
      teams_bidding_info = []
      unassigned_teams.each do |team|
        topic_bids = []
        sign_up_topics.each do |topic|
          bid = Bid.find_by(team_id: team.id, topic_id: topic.id)
          topic_bids << { topic_id: topic.id, priority: bid.priority } if bid
        end
        topic_bids.sort! { |bid| bid[:priority] }
        teams_bidding_info << { team_id: team.id, bids: topic_bids }
      end
      teams_bidding_info
    end
  
    # Assigns available topic slots to teams based on their bidding information.
    # If a certain topic has available slot(s), the team with biggest size and most bids get its first-priority topic.
    # Then the loop breaks to the next team.
    def assign_available_slots(teams_bidding_info)
      teams_bidding_info.each do |tb|
        tb[:bids].each do |bid|
          topic_id = bid[:topic_id]
          max_choosers = SignUpTopic.find(topic_id).try(:max_choosers)
          SignedUpTeam.create(team_id: tb[:team_id], topic_id: topic_id) if SignedUpTeam.where(topic_id: topic_id).count < max_choosers
        end
      end
    end
  
  end