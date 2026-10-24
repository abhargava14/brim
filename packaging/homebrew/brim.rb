# Homebrew formula (builds from source). Put it in a tap, e.g. abhargava14/homebrew-tap, then:
#   brew install --HEAD abhargava14/tap/brim
class Brim < Formula
  desc "Living notch for your Mac: music, calendar, timers, stats and AI usage limits"
  homepage "https://github.com/abhargava14/brim"
  head "https://github.com/abhargava14/brim.git", branch: "main"
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

      This formula builds from source (HEAD) on your Mac, so Gatekeeper doesn't ask.
      Keychain and privacy approvals carry over between updates.
    EOS
  end

  test do
    assert_match "brim", shell_output("#{bin}/brim help")
  end
end
