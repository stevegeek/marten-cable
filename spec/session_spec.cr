require "spec"
require "http/request"
require "../src/marten_cable"

# Marten requires SOME settings to be defined before referencing
# Marten.settings — at minimum a 32-byte secret key for the encryptor
# used by the cookie session store.
Marten.configure do |config|
  config.secret_key = "marten-cable-session-spec-secret-key-32+chars"
  config.installed_apps = [] of Marten::Apps::Config.class
end

# Helper: hand-craft a Marten session cookie value the same way
# Marten::HTTP::Session::Store::Cookie#save does:
#   encryptor.encrypt(session_hash.to_json, expires: ...)
private def make_session_cookie(data : Hash(String, String)) : String
  encryptor = Marten::Core::Encryptor.new
  encryptor.encrypt(
    value: data.to_json,
    expires: Time.local + 1.hour,
  )
end

private def request_with_cookie(name : String, value : String) : HTTP::Request
  req = HTTP::Request.new("GET", "/cable")
  req.cookies[name] = value
  req
end

describe MartenCable::Session do
  describe ".for" do
    it "returns nil when no session cookie is present" do
      req = HTTP::Request.new("GET", "/cable")
      MartenCable::Session.for(req).should be_nil
    end

    it "returns a loaded session store for a valid cookie" do
      cookie_value = make_session_cookie({"user_id" => "42", "role" => "admin"})
      req = request_with_cookie(Marten.settings.sessions.cookie_name, cookie_value)

      store = MartenCable::Session.for(req)
      raise "expected a session store" if store.nil?

      store["user_id"]?.should eq("42")
      store["role"]?.should eq("admin")
      store["missing"]?.should be_nil
    end

    it "honors a custom cookie_name setting" do
      original = Marten.settings.sessions.cookie_name
      begin
        Marten.settings.sessions.cookie_name = "my_session"
        cookie_value = make_session_cookie({"k" => "v"})
        req = request_with_cookie("my_session", cookie_value)

        store = MartenCable::Session.for(req)
        raise "expected a session store" if store.nil?
        store["k"]?.should eq("v")

        # Wrong cookie name → no session.
        bad_req = request_with_cookie("sessionid", cookie_value)
        MartenCable::Session.for(bad_req).should be_nil
      ensure
        Marten.settings.sessions.cookie_name = original
      end
    end

    it "returns a store that loads to empty on tampered/garbage values" do
      # Marten's Cookie#load rescues Encryptor::InvalidValueError and
      # returns an empty SessionHash, so the helper still hands back a
      # store — the caller sees no keys.
      req = request_with_cookie(Marten.settings.sessions.cookie_name, "not-a-real-cookie")

      store = MartenCable::Session.for(req)
      raise "expected a session store" if store.nil?
      store["user_id"]?.should be_nil
    end
  end
end
