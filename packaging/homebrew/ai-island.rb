# Homebrew formula (builds from source). Put it in a tap, e.g. OWNER/homebrew-tap, then:
#   brew install --HEAD OWNER/tap/ai-island
class AiIsland < Formula
  desc "AI usage tracker that lives in your Mac's notch (Claude Code, Codex, Copilot, Cursor, …)"
  homepage "https://github.com/OWNER/ai-island"
  head "https://github.com/OWNER/ai-island.git", branch: "main"
  license "MIT"

  depends_on xcode: ["15.0", :build]
  depends_on macos: :ventura

  def install
    system "./scripts/build-app.sh"
    prefix.install "build/AI Island.app"
    bin.install_symlink prefix/"AI Island.app/Contents/Helpers/ai-island"
  end

  def caveats
    <<~EOS
      Open the app once (it lives in your notch and menu bar):
        open "#{prefix}/AI Island.app"
      Or link it into /Applications:
        ln -sf "#{prefix}/AI Island.app" /Applications/

      Connect tools from the terminal:
        ai-island add claude
        ai-island status
    EOS
  end

  test do
    assert_match "ai-island", shell_output("#{bin}/ai-island help")
  end
end
