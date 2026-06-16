import SwiftUI

struct RootView: View {
    var body: some View {
        ConversationView()
            .background(ChatStyle.pageBackground)
    }
}

#Preview {
    RootView()
}
