# frozen_string_literal: true

RSpec.describe ExtraLocalesController do
  around { |example| allow_missing_translations(&example) }

  describe "#show" do
    it "won't work with a weird parameter" do
      get "/extra-locales/-invalid..character!!"
      expect(response.status).to eq(404)
    end

    it "needs a valid bundle" do
      get "/extra-locales/made-up-bundle"
      expect(response.status).to eq(403)
    end

    it "requires a valid version" do
      get "/extra-locales/overrides", params: { v: "a" }
      expect(response.status).to eq(400)

      get "/extra-locales/overrides?v[foo]=1"
      expect(response.status).to eq(400)
    end

    it "caches for 1 year if version is provided and it matches current hash" do
      get "/extra-locales/admin", params: { v: ExtraLocalesController.bundle_js_hash("admin") }
      expect(response.status).to eq(200)
      expect(response.headers["Cache-Control"]).to eq("max-age=31556952, public, immutable")
    end

    it "does not cache at all if version is invalid" do
      get "/extra-locales/admin", params: { v: "a" * 32 }
      expect(response.status).to eq(200)
      expect(response.headers["Cache-Control"]).not_to include("max-age", "public", "immutable")
    end

    it "doesn’t generate the bundle twice" do
      described_class.expects(:bundle_js).returns("JS").once
      get "/extra-locales/admin", params: { v: "a" * 32 }
    end

    context "with plugin" do
      before do
        JsLocaleHelper.clear_cache!
        JsLocaleHelper
          .expects(:plugin_translations)
          .with(any_of("en", "en_GB"))
          .returns(
            "admin_js" => {
              "admin" => {
                "site_settings" => {
                  "categories" => {
                    "github_badges" => "GitHub Badges",
                  },
                },
              },
            },
          )
          .at_least_once
      end

      after { JsLocaleHelper.clear_cache! }

      it "includes plugin translations" do
        get "/extra-locales/admin"
        expect(response.status).to eq(200)
        expect(response.body.include?("github_badges")).to eq(true)
      end
    end

    context "with overridden translations" do
      after { I18n.reload! }

      it "works for anonymous users" do
        TranslationOverride.upsert!(I18n.locale, "js.some_key", "client-side translation")

        get "/extra-locales/overrides",
            params: {
              v: ExtraLocalesController.bundle_js_hash("overrides"),
            }
        expect(response.status).to eq(200)
        expect(response.headers["Cache-Control"]).to eq("max-age=31556952, public, immutable")
      end

      it "returns nothing when there are not overridden translations" do
        get "/extra-locales/overrides"
        expect(response.status).to eq(200)
        expect(response.body).to be_empty
      end

      context "with translations" do
        it "returns the correct translations" do
          TranslationOverride.upsert!(I18n.locale, "js.some_key", "client-side translation")
          TranslationOverride.upsert!(
            I18n.locale,
            "js.client_MF",
            "{NUM_RESULTS, plural, one {1 result} other {many} }",
          )
          TranslationOverride.upsert!(I18n.locale, "admin_js.another_key", "admin client js")
          TranslationOverride.upsert!(I18n.locale, "server.some_key", "server-side translation")
          TranslationOverride.upsert!(
            I18n.locale,
            "server.some_MF",
            "{NUM_RESULTS, plural, one {1 result} other {many} }",
          )

          get "/extra-locales/overrides"
          expect(response.status).to eq(200)
          expect(response.body).to_not include("server.some_key", "server.some_MF")

          ctx = MiniRacer::Context.new
          ctx.eval("I18n = {};")
          ctx.eval(response.body)

          expect(ctx.eval("I18n._overrides['#{I18n.locale}']['js.some_key']")).to eq(
            "client-side translation",
          )
          expect(ctx.eval("I18n._overrides['#{I18n.locale}']['js.client_MF'] === undefined")).to eq(
            true,
          )
          expect(ctx.eval("I18n._overrides['#{I18n.locale}']['admin_js.another_key']")).to eq(
            "admin client js",
          )
        end

        it "returns overrides from fallback locale" do
          TranslationOverride.upsert!(:en, "js.some_key", "some key (en)")
          TranslationOverride.upsert!(:fr, "js.some_key", "some key (fr)")
          TranslationOverride.upsert!(:en, "js.only_en", "only English")
          TranslationOverride.upsert!(:fr, "js.only_fr", "only French")
          TranslationOverride.upsert!(
            :en,
            "js.some_client_MF",
            "{NUM_RESULTS, plural, one {1 result} other {many} }",
          )
          TranslationOverride.upsert!(
            :fr,
            "js.some_client_MF",
            "{NUM_RESULTS, plural, one {1 result} other {many} }",
          )
          TranslationOverride.upsert!(
            :en,
            "js.only_en_MF",
            "{NUM_RESULTS, plural, one {1 result} other {many} }",
          )
          TranslationOverride.upsert!(
            :fr,
            "js.only_fr_MF",
            "{NUM_RESULTS, plural, one {1 result} other {many} }",
          )

          SiteSetting.allow_user_locale = true
          user = Fabricate(:user, locale: :fr)
          sign_in(user)

          get "/extra-locales/overrides"
          expect(response.status).to eq(200)

          ctx = MiniRacer::Context.new
          ctx.eval("I18n = {};")
          ctx.eval(response.body)

          overrides = ctx.eval("I18n._overrides")
          expect(overrides.keys).to contain_exactly("en", "fr")
          expect(overrides["en"]).to eq({ "js.only_en" => "only English" })
          expect(overrides["fr"]).to eq(
            { "js.some_key" => "some key (fr)", "js.only_fr" => "only French" },
          )
        end
      end
    end

    context "when requesting MessageFormat translations" do
      before { JsLocaleHelper.stubs(:output_MF).with("en").returns("MF_TRANSLATIONS") }

      it "returns the translations properly" do
        get "/extra-locales/mf"
        expect(response.body).to eq("MF_TRANSLATIONS")
      end
    end
  end

  describe ".bundle_js_hash" do
    it "doesn't call bundle_js more than once for the same locale and bundle" do
      I18n.locale = :de
      ExtraLocalesController.expects(:bundle_js).with("admin").returns("admin_js DE").once
      expected_hash_de = Digest::MD5.hexdigest("admin_js DE")

      expect(ExtraLocalesController.bundle_js_hash("admin")).to eq(expected_hash_de)
      expect(ExtraLocalesController.bundle_js_hash("admin")).to eq(expected_hash_de)

      I18n.locale = :fr
      ExtraLocalesController.expects(:bundle_js).with("admin").returns("admin_js FR").once
      expected_hash_fr = Digest::MD5.hexdigest("admin_js FR")

      expect(ExtraLocalesController.bundle_js_hash("admin")).to eq(expected_hash_fr)
      expect(ExtraLocalesController.bundle_js_hash("admin")).to eq(expected_hash_fr)

      I18n.locale = :de
      expect(ExtraLocalesController.bundle_js_hash("admin")).to eq(expected_hash_de)

      ExtraLocalesController.expects(:bundle_js).with("wizard").returns("wizard_js DE").once
      expected_hash_de = Digest::MD5.hexdigest("wizard_js DE")

      expect(ExtraLocalesController.bundle_js_hash("wizard")).to eq(expected_hash_de)
      expect(ExtraLocalesController.bundle_js_hash("wizard")).to eq(expected_hash_de)
    end
  end

  describe ".client_overrides_exist?" do
    after do
      I18n.reload!
      ExtraLocalesController.clear_cache!
    end

    it "returns false if there are no client-side translation overrides" do
      expect(ExtraLocalesController.client_overrides_exist?).to eq(false)

      TranslationOverride.upsert!(I18n.locale, "server.some_key", "server-side translation")
      expect(ExtraLocalesController.client_overrides_exist?).to eq(false)
    end

    it "returns true if there are client-side translation overrides" do
      expect(ExtraLocalesController.client_overrides_exist?).to eq(false)

      TranslationOverride.upsert!(I18n.locale, "js.some_key", "client-side translation")
      expect(ExtraLocalesController.client_overrides_exist?).to eq(true)
    end
  end

  describe ".bundle_js_with_hash" do
    before { described_class.stubs(:bundle_js).with("admin").returns("JS") }

    it "returns both JS and its hash for a given bundle" do
      expect(described_class.bundle_js_with_hash("admin")).to eq(
        ["JS", Digest::MD5.hexdigest("JS")],
      )
    end
  end

  describe ".url" do
    it "works" do
      expect(ExtraLocalesController.url("admin")).to start_with("/extra-locales/admin?v=")
    end

    it "includes subfolder path" do
      set_subfolder "/forum"
      expect(ExtraLocalesController.url("admin")).to start_with("/forum/extra-locales/admin?v=")
    end

    it "includes CDN" do
      set_cdn_url "https://cdn.example.com"
      expect(ExtraLocalesController.url("admin")).to start_with(
        "https://cdn.example.com/extra-locales/admin?v=",
      )
    end
  end
end
