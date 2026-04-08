class Orbital < Formula
  desc "Orbital — AI CLI environment manager for Claude Code, Codex, and Gemini CLI"
  homepage "https://github.com/OffskyLab/orbital"
  url "https://github.com/OffskyLab/orbital/archive/refs/tags/v0.1.4.tar.gz"
  # sha256 updated on each release — run: brew fetch --build-from-source orbital
  sha256 "PLACEHOLDER"
  license "Apache-2.0"
  head "https://github.com/OffskyLab/orbital.git", branch: "main"

  depends_on xcode: ["15.0", :build]
  depends_on :macos

  def install
    system "swift", "build", "--configuration", "release", "--disable-sandbox"
    bin.install ".build/release/orbital"
  end

  def post_install
    # Write shell integration to rc file (bash/zsh auto-detected).
    # This only adds the eval line if not already present.
    system "#{bin}/orbital", "setup"
  end

  def caveats
    <<~EOS
      Shell integration has been added to your rc file automatically.
      To activate in your current shell, run:

        eval "$(orbital setup)"
    EOS
  end

  test do
    assert_match "0.1.4", shell_output("#{bin}/orbital --version")
  end
end
