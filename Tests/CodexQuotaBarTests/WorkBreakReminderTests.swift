import Testing
@testable import CodexQuotaBar

final class WorkBreakReminderTests {
    @Test func testMessageDeckAvoidsImmediateRepeats() {
        var deck = BreakReminderMessageDeck()
        let first = deck.next { _ in 3 }
        let second = deck.next { _ in 3 }
        let third = deck.next { _ in 4 }

        #expect(first != second)
        #expect(second != third)
    }

    @Test func testMessagesAreShortEnoughForNotifications() {
        #expect(BreakReminderMessageDeck.messages.count >= 12)
        for message in BreakReminderMessageDeck.messages {
            #expect(!(message.title.isEmpty))
            #expect(!(message.body.isEmpty))
            #expect(message.title.count <= 20)
            #expect(message.body.count <= 55)
        }
    }
}
