PhoenixTest
Standing: UNVERIFIED
PhoenixTest provides a unified way of writing feature tests -- regardless of whether you're testing LiveView pages or static pages.

It also handles navigation between LiveView and static pages seamlessly. So, you don't have to worry about what type of page you're visiting. Just write the tests from the user's perspective.

Thus, you can test a flow going from static to LiveView pages and back without having to worry about the underlying implementation.

This is a sample flow:

test "admin can create a user", %{conn: conn} do
  conn
  |> visit("/")
  |> click_link("Users")
  |> fill_in("Name", with: "Aragorn")
  |> choose("Ranger")
  |> assert_has(".user", text: "Aragorn")
end

Note that PhoenixTest does not handle JavaScript. If you're looking for something that supports JavaScript, take a look at Wallaby or the external PhoenixTest.Playwright driver.

Setup
PhoenixTest requires Phoenix 1.7+ and LiveView 0.20+. It may work with earlier versions, but I have not tested that.

Installation
Add phoenix_test to your list of dependencies in mix.exs:

def deps do
  [
    {:phoenix_test, "~> 0.7.0", only: :test, runtime: false}
  ]
end

Configuration
In config/test.exs specify the endpoint to be used for routing requests:

config :phoenix_test, :endpoint, MyAppWeb.Endpoint

Getting PhoenixTest helpers
PhoenixTest helpers can be included via import PhoenixTest.

But since each test needs a conn struct to get started, you'll likely want to set up a few things before that.

There are two ways to do that.

With ConnCase
If you plan to use ConnCase solely for PhoenixTest, then you can import the helpers there:

using do
  quote do
    # importing other things for ConnCase

    import PhoenixTest

    # doing other setup for ConnCase
  end
end

Adding a FeatureCase
If you want to create your own FeatureCase helper module like ConnCase, you can copy the code below which can be used from your tests (replace MyApp with your app's name):

defmodule MyAppWeb.FeatureCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      use MyAppWeb, :verified_routes

      import MyAppWeb.FeatureCase

      import PhoenixTest
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MyApp.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end

Note that we assume your Phoenix project is using Ecto and its phenomenal SQL.Sandbox. If it doesn't, feel free to remove the SQL.Sandbox code above.

Usage
Now that we have all the setup out of the way, we can create tests like this:

# test/my_app_web/features/admin_can_create_user_test.exs

defmodule MyAppWeb.AdminCanCreateUserTest do
  use MyAppWeb.FeatureCase, async: true

  test "admin can create user", %{conn: conn} do
    conn
    |> visit("/")
    |> click_link("Users")
    |> fill_in("Name", with: "Aragorn")
    |> fill_in("Email", with: "aragorn@dunedain.com")
    |> click_button("Create")
    |> assert_has(".user", text: "Aragorn")
  end
end

Filling out forms
We can fill out forms by targetting their inputs, selects, etc. by label:

test "admin can create user", %{conn: conn} do
  conn
  |> visit("/")
  |> click_link("Users")
  |> fill_in("Name", with: "Aragorn")
  |> select("Elessar", from: "Aliases")
  |> choose("Human") # <- choose a radio option
  |> check("Ranger") # <- check a checkbox
  |> click_button("Create")
  |> assert_has(".user", text: "Aragorn")
end

For more info, see fill_in/3, select/3, choose/3, check/2, uncheck/2.

Submitting forms without clicking a button
Once we've filled out a form, you can click a button with click_button/2 to submit the form. But sometimes you want to emulate what would happen by just pressing <Enter>.

For that case, you can use submit/1 to submit the form you just filled out.

session
|> fill_in("Name", with: "Aragorn")
|> check("Ranger")
|> submit()

For more info, see submit/1.

Targeting which form to fill out
If you find yourself in a situation where you have multiple forms with the same labels (even when those labels point to different inputs), then you might have to scope your form-filling.

To do that, you can scope all of the form helpers using within/3:

session
|> within("#user-form", fn session ->
  session
  |> fill_in("Name", with: "Aragorn")
  |> check("Ranger")
  |> click_button("Create")
end)

For more info, see within/3.