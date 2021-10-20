class AssignmentForm
  attr_accessor :assignment,
                :assignment_questionnaires,
                :due_dates,
                :tag_prompt_deployments,
                :is_conference_assignment,
                :auto_assign_mentor

  attr_accessor :errors

  DEFAULT_MAX_TEAM_SIZE = 1

  def initialize(args = {})
    @assignment = Assignment.new(args[:assignment])
    if args[:assignment].nil?
      @assignment.course = Course.find(args[:parent_id]) if args[:parent_id]
      @assignment.instructor = @assignment.course.instructor if @assignment.course
      @assignment.max_team_size = DEFAULT_MAX_TEAM_SIZE
    end
    @assignment.num_review_of_reviews = @assignment.num_metareviews_allowed
    @assignment_questionnaires = Array(args[:assignment_questionnaires])
    @due_dates = Array(args[:due_dates])
  end

  # create a form object for this assignment_id
  def self.create_form_object(assignment_id)
    assignment_form = AssignmentForm.new
    assignment_form.assignment = Assignment.find(assignment_id)
    assignment_form.assignment_questionnaires = AssignmentQuestionnaire.where(assignment_id: assignment_id)
    assignment_form.due_dates = AssignmentDueDate.where(parent_id: assignment_id)
    assignment_form.set_up_assignment_review
    assignment_form.tag_prompt_deployments = TagPromptDeployment.where(assignment_id: assignment_id)
    assignment_form
  end

  def rubric_weight_error(attributes)
    error = false
    attributes[:assignment_questionnaire].each do |assignment_questionnaire|
      # Check rubrics to make sure weight is 0 if there are no Scored Questions
      scored_questionnaire = false
      questionnaire = Questionnaire.find(assignment_questionnaire[:questionnaire_id])
      questions = Question.where(questionnaire_id: questionnaire.id)
      questions.each do |question|
        if question.is_a? ScoredQuestion
          scored_questionnaire = true
        end
      end
      unless scored_questionnaire || assignment_questionnaire[:questionnaire_weight].to_i.zero?
        error = true
      end
    end
    error
  end

  def update(attributes, user, vary_by_topic_desired = false)
    @has_errors = false
    has_late_policy = false
    if attributes[:assignment][:late_policy_id].to_i > 0
      has_late_policy = true
    else
      attributes[:assignment][:late_policy_id] = nil
    end
    update_assignment(attributes[:assignment])
    update_assignment_questionnaires(attributes[:assignment_questionnaire]) unless @has_errors
    update_assignment_questionnaires(attributes[:topic_questionnaire]) unless @has_errors || attributes[:assignment][:vary_by_topic] == 'false'
    update_due_dates(attributes[:due_date], user) unless @has_errors
    update_assigned_badges(attributes[:badge], attributes[:assignment]) unless @has_errors
    add_simicheck_to_delayed_queue(attributes[:assignment][:simicheck])
    # delete the old queued items and recreate new ones if the assignment has late policy.
    if attributes[:due_date] and !@has_errors and has_late_policy
      delete_from_delayed_queue
      add_to_delayed_queue
    end
    update_tag_prompt_deployments(attributes[:tag_prompt_deployments])
    !@has_errors
  end

  alias update_attributes update

  # Code to update values of assignment
  def update_assignment(attributes)
    unless @assignment.update_attributes(attributes)
      @errors = @assignment.errors.to_s
      @has_errors = true
    end
    @assignment.num_review_of_reviews = @assignment.num_metareviews_allowed
    @assignment.num_reviews = @assignment.num_reviews_allowed
  end

  # code to save assignment questionnaires updated in the Rubrics and Topics tabs
  def update_assignment_questionnaires(attributes)
    return if attributes.nil? || attributes.empty?
    if attributes[0].key?(:questionnaire_weight)
      validate_assignment_questionnaires_weights(attributes)
      @errors = @assignment.errors.to_s
      topic_id = nil
    end
    unless @has_errors
      # Update AQ if found, otherwise create new entry
      attributes.each do |attr|
        unless attr[:questionnaire_id].blank?
          questionnaire_type = Questionnaire.find(attr[:questionnaire_id]).type
          topic_id = attr[:topic_id] if attr.key?(:topic_id)
          aq = assignment_questionnaire(questionnaire_type, attr[:used_in_round], topic_id)
          if aq.id.nil?
            unless aq.save
              @errors = @assignment.errors.to_s
              @has_errors = true
              next
            end
          end
          unless aq.update_attributes(attr)
            @errors = @assignment.errors.to_s
            @has_errors = true
          end
        end
      end
    end
  end

  # checks to see if the sum of weights of all rubrics add up to either 0 or 100%
  def validate_assignment_questionnaires_weights(attributes)
    total_weight = 0
    attributes.each do |assignment_questionnaire|
      total_weight += assignment_questionnaire[:questionnaire_weight].to_i
    end
    if total_weight != 0 and total_weight != 100
      @assignment.errors.add(:message, 'Total weight of rubrics should add up to either 0 or 100%')
      @has_errors = true
    end
  end

  # s required by answer tagging
  def update_tag_prompt_deployments(attributes)
    unless attributes.nil?
      attributes.each do |key, value|
        TagPromptDeployment.where(id: value['deleted']).delete_all if value.key?('deleted')
        # assume if tag_prompt is there, then id, question_type, answer_length_threshold must also be there since the inputs are coupled
        next unless value.key?('tag_prompt')
        for i in 0..value['tag_prompt'].count - 1
          tag_dep = nil
          if !(value['id'][i] == "undefined" or value['id'][i] == "null" or value['id'][i].nil?)
            tag_dep = TagPromptDeployment.find(value['id'][i])
            if tag_dep
              tag_dep.update(assignment_id: @assignment.id,
                             questionnaire_id: key,
                             tag_prompt_id: value['tag_prompt'][i],
                             question_type: value['question_type'][i],
                             answer_length_threshold: value['answer_length_threshold'][i])
            end
          else
            tag_dep = TagPromptDeployment.new(assignment_id: @assignment.id,
                                              questionnaire_id: key,
                                              tag_prompt_id: value['tag_prompt'][i],
                                              question_type: value['question_type'][i],
                                              answer_length_threshold: value['answer_length_threshold'][i]).save
          end
        end
      end
    end
  end
  # end required by answer tagging

  # code to save due dates
  def update_due_dates(attributes, user)
    return false unless attributes
    attributes.each do |due_date|
      next if due_date[:due_at].blank?
      # parse the dd and convert it to utc before saving it to db
      # eg. 2015-06-22 12:05:00 -0400
      current_local_time = Time.parse(due_date[:due_at][0..15])
      tz = ActiveSupport::TimeZone[user.timezonepref].tzinfo
      utc_time = tz.local_to_utc(Time.local(current_local_time.year,
                                            current_local_time.month,
                                            current_local_time.day,
                                            current_local_time.strftime('%H').to_i,
                                            current_local_time.strftime('%M').to_i,
                                            current_local_time.strftime('%S').to_i))
      due_date[:due_at] = utc_time
      if due_date[:id].nil? or due_date[:id].blank?
        dd = AssignmentDueDate.new(due_date)
        @has_errors = true unless dd.save
      else
        dd = AssignmentDueDate.find(due_date[:id])
        # get deadline for review
        @has_errors = true unless dd.update_attributes(due_date)
      end
      @errors += @assignment.errors.to_s if @has_errors
    end
  end

  # Adds badges to assignment badges table as part of E1822
  def update_assigned_badges(badge, assignment)
    if assignment and badge
      AssignmentBadge.where(assignment_id: assignment[:id]).map(&:id).each do |assigned_badge_id|
        AssignmentBadge.delete(assigned_badge_id) unless badge[:id].include?(assigned_badge_id)
      end
      badge[:id].each do |badge_id|
        AssignmentBadge.where(badge_id: badge_id[0], assignment_id: assignment[:id]).first_or_create
      end
    end
  end

  # Adds items to delayed_jobs queue for this assignment
  def add_to_delayed_queue
    duedates = AssignmentDueDate.where(parent_id: @assignment.id)
    duedates.each do |due_date|
      deadline_type = DeadlineType.find(due_date.deadline_type_id).name
      diff_btw_time_left_and_threshold_duration, min_left_duration = DueDate.get_time_diff_btw_due_date_and_now(due_date)
      next unless diff_btw_time_left_and_threshold_duration > 0
      delayed_job_id = add_delayed_job(deadline_type, due_date, diff_btw_time_left_and_threshold_duration)
      due_date.update_attribute(:delayed_job_id, delayed_job_id)
      # If the deadline type is review, add a delayed job to drop outstanding review
      add_drop_outstanding_reviews_delayed_job(min_left_duration) if deadline_type == "review"
    end
  end

  # Find an AQ based on the given values
  def assignment_questionnaire(questionnaire_type, round_number, topic_id)
    round_number = nil if round_number.blank?
    topic_id = nil if topic_id.blank?
    if @assignment.vary_by_round && @assignment.vary_by_topic
        # Get all AQs for the assignment and specified round number and topic
        assignment_questionnaires = AssignmentQuestionnaire.where(assignment_id: @assignment.id, used_in_round: round_number, topic_id: topic_id)
        assignment_questionnaires.each do |aq|
          # If the AQ questionnaire matches the type of the questionnaire that needs to be updated, return it
          return aq if !aq.questionnaire_id.nil? && Questionnaire.find(aq.questionnaire_id).type == questionnaire_type
        end
    elsif @assignment.vary_by_round
        # Get all AQs for the assignment and specified round number by round #
        assignment_questionnaires = AssignmentQuestionnaire.where(assignment_id: @assignment.id, used_in_round: round_number)
        assignment_questionnaires.each do |aq|
          # If the AQ questionnaire matches the type of the questionnaire that needs to be updated, return it
          return aq if !aq.questionnaire_id.nil? && Questionnaire.find(aq.questionnaire_id).type == questionnaire_type
        end
    elsif @assignment.vary_by_topic
        # Get all AQs for the assignment and specified round number by topic
        assignment_questionnaires = AssignmentQuestionnaire.where(assignment_id: @assignment.id, topic_id: topic_id)
        assignment_questionnaires.each do |aq|
          # If the AQ questionnaire matches the type of the questionnaire that needs to be updated, return it
          return aq if !aq.questionnaire_id.nil? && Questionnaire.find(aq.questionnaire_id).type == questionnaire_type
        end
    else
        # Get all AQs for the assignment
        assignment_questionnaires = AssignmentQuestionnaire.where(assignment_id: @assignment.id)
        assignment_questionnaires.each do |aq|
          # If the AQ questionnaire matches the type of the questionnaire that needs to be updated, return it
          return aq if !aq.questionnaire_id.nil? && Questionnaire.find(aq.questionnaire_id).type == questionnaire_type
        end
    end

    # Create a new AQ if it was not found based on the attributes
    default_weight = {}
    default_weight['ReviewQuestionnaire'] = 100
    default_weight['MetareviewQuestionnaire'] = 0
    default_weight['AuthorFeedbackQuestionnaire'] = 0
    default_weight['TeammateReviewQuestionnaire'] = 0
    default_weight['BookmarkRatingQuestionnaire'] = 0
    default_aq = AssignmentQuestionnaire.where(user_id: @assignment.instructor_id, assignment_id: nil, questionnaire_id: nil).first
    default_limit = if default_aq.blank?
                      15
                    else
                      default_aq.notification_limit
                    end

    aq = AssignmentQuestionnaire.new
    aq.questionnaire_weight = default_weight[questionnaire_type]
    aq.notification_limit = default_limit
    aq.assignment = @assignment
    aq
  end

  # Find a questionnaire for the given AQ and questionnaire type
  def questionnaire(assignment_questionnaire, questionnaire_type)
    return Object.const_get(questionnaire_type).new if assignment_questionnaire.nil?
    questionnaire = Questionnaire.find_by(id: assignment_questionnaire.questionnaire_id)
    return questionnaire unless questionnaire.nil?
    Object.const_get(questionnaire_type).new
  end

  # add DelayedJob into queue and return it
  def add_delayed_job(deadline_type, due_date, min_left)
    seconds_left = min_left.to_i
    MailWorker.perform_in(seconds_left, @assignment.id, deadline_type, due_date.due_at)
  end

  def add_drop_outstanding_reviews_delayed_job(min_left)
    seconds_left = min_left.to_i
    DropOutstandingReviewsWorker.perform_in(seconds_left, @assignment.id)
  end

  # Deletes the job with id equal to "delayed_job_id" from the delayed_jobs queue
  def delete_from_delayed_queue
    queue = Sidekiq::Queue.new("jobs")
    queue.each do |job|
      assignment_id = job.args.first
      job.delete if @assignment.id == assignment_id
    end

    queue = Sidekiq::ScheduledSet.new
    queue.each do |job|
      assignment_id = job.args.first
      job.delete if @assignment.id == assignment_id
    end
  end

  def delete(force = nil)
    # delete from delayed_jobs queue related to this assignment
    delete_from_delayed_queue
    @assignment.delete(force)
  end

  # Save the assignment
  def save
    @assignment.save
  end

  # create a node for the assignment
  def create_assignment_node
    @assignment.create_node unless @assignment.nil?
  end

  # NOTE: many of these functions actually belongs to other models
  #====setup methods for new and edit method=====#
  def set_up_assignment_review
    set_up_defaults

    submissions = @assignment.find_due_dates('submission')
    reviews = @assignment.find_due_dates('review')

    @assignment.directory_path = nil if @assignment.directory_path.empty?
  end

  def staggered_deadline
    @assignment.staggered_deadline = false if @assignment.staggered_deadline.nil?
  end

  def availability_flag
    @assignment.availability_flag = false if @assignment.availability_flag.nil?
  end

  def micro_task
    @assignment.microtask = false if @assignment.microtask.nil?
  end

  def reviews_visible_to_all
    @assignment.reviews_visible_to_all = false if @assignment.reviews_visible_to_all.nil?
  end

  def review_assignment_strategy
    @assignment.review_assignment_strategy = '' if @assignment.review_assignment_strategy.nil?
  end

  def require_quiz
    if @assignment.require_quiz.nil?
      @assignment.require_quiz = false
      @assignment.num_quiz_questions = 0
    end
  end

  # NOTE: unfortunately this method is needed due to bad data in db @_@
  def set_up_defaults
    staggered_deadline
    availability_flag
    micro_task
    reviews_visible_to_all
    review_assignment_strategy
    require_quiz
  end

  def add_simicheck_to_delayed_queue(simicheck_delay_hours_string)
    delete_from_delayed_queue
    simicheck_delay_hours = simicheck_delay_hours_string.to_i
    if simicheck_delay_hours >= 0
      simicheck_delay_hours_duration = simicheck_delay_hours.hour # Convert to ActiveSupport::Duration
      duedates = AssignmentDueDate.where(parent_id: @assignment.id)
      duedates.each do |due_date|
        next if DeadlineType.find(due_date.deadline_type_id).name != "submission"
        enqueue_simicheck_task(due_date, simicheck_delay_hours_duration)
      end
    end
  end

  def enqueue_simicheck_task(due_date, simicheck_delay_hours_duration)
    dequeue_time_as_seconds_duration_from_now = DueDate.get_dequeue_time_as_seconds_duration_from_now(due_date, simicheck_delay_hours_duration)

    SimicheckWorker.perform_in(dequeue_time_as_seconds_duration_from_now.to_i, @assignment.id)
  end

  # Copies the inputted assignment into new one and returns the new assignment id
  def self.copy(assignment_id, user)
    Assignment.record_timestamps = false
    old_assign = Assignment.find(assignment_id)
    new_assign = old_assign.dup
    user.set_instructor(new_assign)
    new_assign.update_attribute('name', 'Copy of ' + new_assign.name)
    new_assign.update_attribute('created_at', Time.now)
    new_assign.update_attribute('updated_at', Time.now)
    new_assign.update_attribute('directory_path', new_assign.directory_path + '_copy') if new_assign.directory_path.present?
    new_assign.copy_flag = true
    if new_assign.save
      Assignment.record_timestamps = true
      copy_assignment_questionnaire(old_assign, new_assign, user)
      AssignmentDueDate.copy(old_assign.id, new_assign.id)
      new_assign.create_node
      new_assign_id = new_assign.id
      # also copy topics from old assignment
      topics = SignUpTopic.where(assignment_id: old_assign.id)
      topics.each do |topic|
        SignUpTopic.create(topic_name: topic.topic_name, assignment_id: new_assign_id, max_choosers: topic.max_choosers, category: topic.category, topic_identifier: topic.topic_identifier, micropayment: topic.micropayment)
      end
    else
      new_assign_id = nil
    end
    new_assign_id
  end

  def self.copy_assignment_questionnaire(old_assign, new_assign, user)
    old_assign.assignment_questionnaires.each do |aq|
      AssignmentQuestionnaire.create(
        assignment_id: new_assign.id,
        questionnaire_id: aq.questionnaire_id,
        user_id: user.id,
        notification_limit: aq.notification_limit,
        questionnaire_weight: aq.questionnaire_weight,
        used_in_round: aq.used_in_round,
        dropdown: aq.dropdown,
        topic_id: aq.topic_id
      )
    end
  end

end
