# octokan-ios

In-app support chat for iOS (Swift, SwiftUI). Messages from your users land in your Octokan inbox, and your replies appear
in the app within seconds. iOS 15 and up.

## Setup

From your Xcode project's folder (needs Node.js), add the configure call automatically:

```bash
npx @octokan/cli init <app key> <backend url>
```

Then add the package, the one step Xcode doesn't allow from a command line: **File > Add Package Dependencies**, paste

```
https://github.com/infectedlabs/octokan-ios
```

and press **Add Package**.

## Manual setup

```swift
import OctokanSDK

@main
struct MyApp: App {
    init() {
        Octokan.configure(appId: "app_xxxxxxxxxxxx", baseURL: URL(string: "https://YOUR-BACKEND")!)
    }
    var body: some Scene { WindowGroup { ContentView() } }
}

OctokanChatButton("Chat with us")    // SwiftUI
Octokan.presentChat()                // UIKit or any custom button
Octokan.identify(id: user.id, email: user.email, name: user.name)   // optional
Octokan.reset()                      // on sign-out
```

Nothing is sent or stored until the person opens the chat. Messages queue offline and send themselves later.
