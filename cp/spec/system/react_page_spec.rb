require "rails_helper"

RSpec.describe "React page", type: :feature, js: true do
  it "renders the React content" do
    visit root_path

    expect(page).to have_css("[data-testid='react-page']")
    expect(page).to have_text("React ページ")
    expect(page).to have_text("Rails から React を表示しています。")
  end
end
