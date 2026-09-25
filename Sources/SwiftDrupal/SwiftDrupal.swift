// The `drupal` CLI: a local Drupal development environment built on Apple's
// Containerization framework. All logic lives in DrupalKit; this is only the
// process entry point. See docs/cli-contract.md.

import DrupalKit
import Foundation

@main
struct SwiftDrupal {
    static func main() async {
        exit(await DrupalCLI.main())
    }
}
