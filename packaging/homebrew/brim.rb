# Homebrew formula (builds from source). Put it in a tap, e.g. OWNER/homebrew-tap, then:
#   brew install --HEAD OWNER/tap/brim
class Brim < Formula
  desc "AI usage tracker that lives in your Mac's notch (Claude Code, Codex, Copilot, Cursor, …)"
  homepage "https://github.com/OWNER/brim"
  head "https://github.com/OWNER/brim.git", branch: "main"
  license "MIT"

  depends_on xcode: ["15.0", :build]
  depends_on macos: :ventura

  def install
    system "./scripts/build-app.sh"
    prefix.install "build/Brim.app"
    bin.install_symlink prefix/"Brim.app/Contents/Helpers/brim"
    bin.install_symlink prefix/"Brim.app/Contents/Helpers/brim" => "ai-island"
  end

  def caveats
    <<~EOS
      Open the app once (it lives in your notch and menu bar):
        open "#{prefix}/Brim.app"
      Or link it into /Applications:
        ln -sf "#{prefix}/Brim.app" /Applications/

      Connect tools from the terminal:
        brim add claude
        brim status
    EOS
  end

  test do
    assert_match "brim", shell_output("#{bin}/brim help")
  end
end
