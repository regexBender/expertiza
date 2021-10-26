describe MailWorker do
  let(:assignment) { build(:assignment, id: 1, name: "no assignment", participants: [participant], teams: [team]) }
  let(:participant) { build(:participant, id: 1, parent_id: 1, user: user) }
  let(:team) { build(:assignment_team, id: 1, name: 'no team', users: [user], parent_id: 1) }
  let(:user) { build(:student, id: 1, email: 'psingh22@ncsu.edu') }

  before(:each) do
    allow(Assignment).to receive(:find).with(1).and_return(assignment)
    allow(Participant).to receive(:where).with(parent_id: 1).and_return([participant])
  end

  describe 'Tests mailer with sidekiq' do
    it "should send email to required email address with proper content" do
      Sidekiq::Testing.inline!
      MailWorker.perform_async(1, "metareview", "2018-12-31 00:00:01")
      email = ActionMailer::Base.deliveries.first
      expect(email.from[0]).to eq("expertiza.development@gmail.com")
      expect(email.to[0]).to eq("expertiza.development@gmail.com")
      expect(email.subject).to eq('Your Expertiza account and password has been created')
    end

    it "should expect the queue size of one" do
      Sidekiq::Testing.fake!
      MailWorker.perform_in(3.hours, 1, "metareview", "2018-12-31 00:00:01")
      queue = Sidekiq::Queues["jobs"]
      expect(queue.size).to eq(1)
      queue.clear
    end
  end

  describe "test different workers" do
    it "should increase the size of queue by 1 when MailWorker is used" do
      Sidekiq::Testing.fake!
      MailWorker.perform_in(42.minutes, 1, "review", "2021-10-27 00:00:01")
      queue = Sidekiq::Queues["jobs"]
      expect(queue.size).to eq(1)
      queue.clear
    end

    it "should increase the size of queue by 1 when SimicheckWorker is used" do
      Sidekiq::Testing.fake!
      SimicheckWorker.perform_in(42.minutes, 1, "review", "2021-10-27 00:00:01")
      queue = Sidekiq::Queues["jobs"]
      expect(queue.size).to eq(1)
      queue.clear
    end

    it "should increase the size of queue by 1 when DropOutstandingReviewsWorker is used" do
      Sidekiq::Testing.fake!
      DropOutstandingReviewsWorker.perform_in(42.minutes, 1, "review", "2021-10-27 00:00:01")
      queue = Sidekiq::Queues["jobs"]
      expect(queue.size).to eq(1)
      queue.clear
    end
  end
end
