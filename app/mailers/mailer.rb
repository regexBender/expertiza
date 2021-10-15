class Mailer < ActionMailer::Base
  if Rails.env.development? || Rails.env.test?
    default from: 'expertiza.development@gmail.com'
  else
    default from: 'expertiza-support@lists.ncsu.edu'
  end

  def generic_message(defn)
    @partial_name = defn[:body][:partial_name]
    @user = defn[:body][:user]
    @first_name = defn[:body][:first_name]
    @password = defn[:body][:password]
    @new_pct = defn[:body][:new_pct]
    @avg_pct = defn[:body][:avg_pct]
    @assignment = defn[:body][:assignment]
    @conference_variable = defn[:body][:conference_variable]

    defn[:to] = 'expertiza.development@gmail.com' if Rails.env.development? || Rails.env.test?
    mail(subject: defn[:subject],
         to: defn[:to],
         bcc: defn[:bcc])
  end
  
  def request_user_message(defn)
    @user = defn[:body][:user]
    @super_user = defn[:body][:super_user]
    @first_name = defn[:body][:first_name]
    @new_pct = defn[:body][:new_pct]
    @avg_pct = defn[:body][:avg_pct]
    @assignment = defn[:body][:assignment]

    defn[:to] = 'expertiza.development@gmail.com' if Rails.env.development? || Rails.env.test?
    mail(subject: defn[:subject],
         to: defn[:to],
         bcc: defn[:bcc])
  end

  def sync_message(defn)
    @body = defn[:body]
    @type = defn[:body][:type]
    @obj_name = defn[:body][:obj_name]
    @first_name = defn[:body][:first_name]
    @partial_name = defn[:body][:partial_name]

    defn[:to] = 'expertiza.development@gmail.com' if Rails.env.development? || Rails.env.test?
    mail(subject: defn[:subject],
         # content_type: "text/html",
         to: defn[:to])
  end

  def delayed_message(defn)
    ret = mail(subject: defn[:subject],
               body: defn[:body],
               content_type: "text/html",
               bcc: defn[:bcc])
    ExpertizaLogger.info(ret.encoded.to_s)
  end

  def suggested_topic_approved_message(defn)
    @body = defn[:body]
    @topic_name = defn[:body][:approved_topic_name]
    @proposer = defn[:body][:proposer]

    defn[:to] = 'expertiza.development@gmail.com' if Rails.env.development? || Rails.env.test?
    mail(subject: defn[:subject],
         to: defn[:to],
         bcc: defn[:cc])
  end

  def notify_grade_conflict_message(defn)
    @body = defn[:body]

    @assignment = @body[:assignment]
    @reviewer_name = @body[:reviewer_name]
    @type = @body[:type]
    @reviewee_name = @body[:reviewee_name]
    @new_score = @body[:new_score]
    @conflicting_response_url = @body[:conflicting_response_url]
    @summary_url = @body[:summary_url]
    @assignment_edit_url = @body[:assignment_edit_url]

    defn[:to] = 'expertiza.development@gmail.com' if Rails.env.development? || Rails.env.test?
    mail(subject: defn[:subject],
         to: defn[:to])
  end

  #Email about a review rubric being changed. If this is successful, then the answers are deleted for a user's response
  def notify_review_rubric_change(defn)
    @body = defn[:body]
    @answers = defn[:body][:answers]
    @name = defn[:body][:name]
    @assignment_name = defn[:body][:assignment_name]
    defn[:to] = 'expertiza.development@gmail.com' if Rails.env.development? || Rails.env.test?
    mail(:subject => defn[:subject],
         :to => defn[:to])
  end
end
