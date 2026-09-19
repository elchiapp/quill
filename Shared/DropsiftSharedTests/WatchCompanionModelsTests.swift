import Foundation
import Testing
@testable import DropsiftShared

@Test
func watchCompanionSnapshotRoundTripsWithoutLosingLibraryData() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let taskID = UUID(uuidString: "214A78CA-36F4-4E28-8E8E-7F35A332BC51")!
    let entityID = UUID(uuidString: "F67B6801-D3ED-4413-B49F-D47DB91B653F")!
    let snapshot = WatchCompanionSnapshot(
        generatedAt: now,
        items: [
            WatchCompanionItem(
                id: "recording:meeting-1",
                title: "Planning call",
                kind: "Recording",
                date: now,
                description: "Roadmap discussion",
                summary: "The team agreed on the next release."
            ),
        ],
        tasks: [
            WatchCompanionTask(
                id: taskID,
                title: "Send the release plan",
                description: "Share it with the team.",
                dueDate: now.addingTimeInterval(86_400),
                priority: "High",
                isCompleted: false
            ),
        ],
        entities: [
            WatchCompanionEntity(
                id: entityID,
                name: "QVAC",
                kind: "Project",
                summary: "Private AI platform",
                date: nil
            ),
        ]
    )

    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(
        WatchCompanionSnapshot.self,
        from: data
    )

    #expect(decoded == snapshot)
}

@Test
func watchCompanionAnswerRoundTripsSources() throws {
    let answer = WatchCompanionAnswer(
        text: "BKN301 wants an on-device knowledge assistant.",
        sources: ["BKN301 discovery call", "BKN301 follow-up"]
    )

    let data = try JSONEncoder().encode(answer)
    let decoded = try JSONDecoder().decode(
        WatchCompanionAnswer.self,
        from: data
    )

    #expect(decoded == answer)
}
