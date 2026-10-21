# Homebrew cask for the direct-download build. scripts/release-direct.sh fills in the version and
# checksum; the result goes in Casks/ of the chiranjeebhub/homebrew-tap repository, so people can run
#   brew install --cask chiranjeebhub/tap/bucket-browser
cask "bucket-browser" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/chiranjeebhub/Bucket_Browser/releases/download/v#{version}/BucketBrowser.dmg",
      verified: "github.com/chiranjeebhub/Bucket_Browser/"
  name "Bucket Browser"
  desc "Browse Amazon S3, Cloudflare R2 and S3-compatible buckets"
  homepage "https://chiranjeebhub.github.io/bucket-browser-site/"

  livecheck do
    url "https://chiranjeebhub.github.io/bucket-browser-site/appcast.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Bucket Browser.app"

  zap trash: [
    "~/Library/Application Scripts/com.bucketbrowser.app",
    "~/Library/Containers/com.bucketbrowser.app",
  ]
end
