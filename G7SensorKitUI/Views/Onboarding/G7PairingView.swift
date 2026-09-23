//
//  G7PairingView.swift
//  G7SensorKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import G7SensorKit
import SwiftUI

/// Reports the pairing run: that it is working, how long it has been going,
/// and the few things the user can act on.
///
/// Pairing is not one opaque search. Spent applicators in a drawer and the
/// sensor on the arm all advertise, so the run works through them in turn and
/// the screen has to show that much, or a perfectly healthy run looks stuck.
///
/// It shows no more than that while the run is going. Which sensor is under
/// trial, and what each one answered, are true but not actionable, and they
/// read as claims about the user rather than about a candidate: "not your
/// sensor" on a neighbour's sensor invites a hunt for a wrong code, and a
/// visible "attempt 2 of 3" invites cancelling to get a fresh three, which
/// throws away the run's evidence and restarts its clock. So the list is a
/// disclosure, closed while the run is live and open once it has failed,
/// where the same detail explains an outcome instead of narrating a process.
/// The full narration goes to the device log, which is where anyone who
/// needs it is looking anyway.
struct G7PairingView: View {
    @ObservedObject var viewModel: G7PairingViewModel
    var didEditCode: () -> Void

    @Environment(\.guidanceColors) private var guidanceColors

    @State private var rowHeight = CandidateRowHeight.defaultValue
    @State private var isShowingDetails = false

    private var isPulsing: Bool {
        viewModel.isWorking && viewModel.bluetoothProblem == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                // Only the sensor is centred; every line of text starts at the
                // same left edge, which is what makes a screen of changing
                // status readable.
                VStack(alignment: .leading, spacing: 24) {
                    sensorHero
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)

                    status

                    if viewModel.activeCandidate != nil {
                        Text(LocalizedString("If iOS asks to pair with the sensor, tap Pair.", comment: "Hint about the system Bluetooth pairing prompt during G7 pairing"))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !viewModel.candidates.isEmpty {
                        details
                    }
                }
                .padding()
            }

            buttons
                .padding([.horizontal, .bottom])
        }
        .navigationBarBackButtonHidden(viewModel.isWorking)
        .animation(.default, value: viewModel.candidates)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.cancel() }
    }

    // MARK: - Pieces

    /// The sensor being worked on, pictured as the model it advertised itself
    /// as, inside rings that sweep while the run is live.
    private var sensorHero: some View {
        G7SensorHero(model: viewModel.displayModel, isPulsing: isPulsing, outcome: outcome)
    }

    private var outcome: G7SensorHero.Outcome? {
        switch viewModel.state {
        case .succeeded:
            return .succeeded
        case .failed:
            return .failed
        case .idle, .running:
            return nil
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(viewModel.statusTitle)
                .font(.title2)
                .fontWeight(.semibold)

            if viewModel.isWorking, let startedAt = viewModel.scanStartedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
                    Text(String(format: LocalizedString("Looking for %d:%02d", comment: "Elapsed scan time while pairing (1: minutes, 2: seconds)"), elapsed / 60, elapsed % 60))
                        .font(.footnote.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }

            if let problem = viewModel.bluetoothProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .multilineTextAlignment(.leading)
                    .foregroundColor(guidanceColors.critical)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let detail = viewModel.statusDetail {
                Text(detail)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let note = viewModel.serialFilterNote {
                Label(note, systemImage: "line.3.horizontal.decrease.circle")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let notice = viewModel.busyNotice {
                Label(notice, systemImage: "clock.badge.exclamationmark")
                    .font(.footnote)
                    .multilineTextAlignment(.leading)
                    .foregroundColor(guidanceColors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let hint = viewModel.wrongCodeHint {
                Label(hint, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .multilineTextAlignment(.leading)
                    .foregroundColor(guidanceColors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The list, behind a disclosure. Closed while the run is live, open once
    /// it has failed: the same rows that only invite interpretation during a
    /// healthy run are the explanation of an unhealthy one.
    ///
    /// `isShowingDetails` is only ever raised automatically, never lowered, so
    /// a user who opened it mid-run is not overruled when the run ends.
    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { isShowingDetails.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(String(format: LocalizedString("Sensors found (%d)", comment: "Header of the list of sensors discovered while pairing (1: count)"), viewModel.candidates.count))
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isShowingDetails ? 90 : 0))
                }
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.leading, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isShowingDetails ? [] : .isButton)

            if isShowingDetails {
                candidateList
            }
        }
        .onChange(of: viewModel.state) { _, state in
            if case .failed = state {
                isShowingDetails = true
            }
        }
    }

    private var candidateList: some View {
        VStack(alignment: .leading, spacing: 8) {

            // Three at a time, the rest behind a scroll: a drawer of spent
            // applicators all advertise, and an unbounded list would push the
            // status and the way out off the screen.
            ScrollView {
                VStack(spacing: G7PairingView.rowSpacing) {
                    ForEach(viewModel.displayCandidates) { candidate in
                        candidateRow(candidate)
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(key: CandidateRowHeight.self, value: proxy.size.height)
                                }
                            )
                    }
                }
            }
            .frame(height: listHeight)
            .onPreferenceChange(CandidateRowHeight.self) { height in
                if height > 0 {
                    rowHeight = height
                }
            }
        }
    }

    private static let rowSpacing: CGFloat = 8
    /// How many rows are on screen before the list starts scrolling.
    private static let visibleRows = 3

    /// Sized from a measured row rather than a constant, so the list still
    /// shows three whole rows at any Dynamic Type size.
    private var listHeight: CGFloat {
        let rows = CGFloat(min(viewModel.candidates.count, G7PairingView.visibleRows))
        return rows * rowHeight + max(0, rows - 1) * G7PairingView.rowSpacing
    }

    /// The tallest row on screen. Seeded with the height of a row at the
    /// default text size so the first frame is not a collapsed list.
    private struct CandidateRowHeight: PreferenceKey {
        static let defaultValue: CGFloat = 58

        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    private func candidateRow(_ candidate: G7PairingCandidate) -> some View {
        // Greyed out and desaturated says "finished with", which a sensor the
        // run is still waiting on is not.
        let isOut = candidate.status.ruleOutReason != nil && !candidate.isAwaitingASlotToFree

        return HStack(spacing: 12) {
            Group {
                if let model = candidate.model {
                    model.image
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "sensor.tag.radiowaves.forward")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 34, height: 34)
            .saturation(isOut ? 0 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.model?.displayName ?? candidate.name)
                    .font(.subheadline.weight(.medium))
                // Built here rather than from a localized format: the pieces
                // are already translated and a separator is not a sentence,
                // so sending "%1$@ · %2$@" out for translation only invites
                // a broken format string back.
                Text("\(candidate.name) · \(viewModel.detail(for: candidate))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 8)

            trailingIndicator(candidate)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .opacity(isOut ? 0.6 : 1)
    }

    @ViewBuilder
    private func trailingIndicator(_ candidate: G7PairingCandidate) -> some View {
        switch candidate.status {
        case .waiting:
            Image(systemName: "clock")
                .foregroundColor(.secondary)
        case .connecting, .pairing:
            ProgressView()
        case .ruledOut where candidate.isAwaitingASlotToFree:
            // Set aside, not struck off: the run is still listening to this
            // one and will give it another turn if its slot frees.
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundColor(.secondary)
        case .ruledOut:
            // A plain glyph, not `xmark.circle.fill`: nothing in this list is
            // tappable, and a filled x in a circle is the standard "remove
            // this" control, so it invites a tap that does nothing.
            Image(systemName: "xmark")
                .font(.footnote.weight(.semibold))
                .foregroundColor(.secondary)
        case .paired:
            // Green, not `guidanceColors.acceptable`: hosts map that to
            // `.primary` (Trio does), which would show a black tick.
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if case .failed = viewModel.state {
            VStack(spacing: 10) {
                Button(action: { viewModel.retry() }) {
                    Text(LocalizedString("Try Again", comment: "Button title to retry pairing"))
                        .actionButtonStyle(.primary)
                }
                Button(action: didEditCode) {
                    Text(LocalizedString("Change Code", comment: "Button title to go back and edit the pairing code"))
                        .actionButtonStyle(.secondary)
                }
            }
        } else if viewModel.isWorking {
            Button(action: didEditCode) {
                Text(LocalizedString("Cancel", comment: "Button text to cancel G7 setup"))
                    .actionButtonStyle(.secondary)
            }
        }
    }
}
