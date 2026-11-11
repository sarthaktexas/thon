import Foundation

/// Glue between the swipe session and the Reranker: features of a card are computed from the raw pixels of the open micrograph.
extension SwipeSession {
    private var assistDiameterPx: Double { pc.store.project.params.diameterNm * 10 / pc.effectiveAngpix }

    func assistHand(_ x: Double, _ y: Double) -> [Float]? {
        guard !pc.pixels.isEmpty else { return nil }
        return CardFeatures.hand(pixels: pc.pixels, width: Int(pc.imageSize.width), height: Int(pc.imageSize.height), cx: x, cy: y, diameterPx: assistDiameterPx)
    }

    /// Core ML embedding of the card's crop (only when switched on; nil when Vision is unavailable).
    func assistEmbedding(_ x: Double, _ y: Double) -> [Float]? {
        guard reranker.useEmbedding, !pc.pixels.isEmpty else { return nil }
        let half = min(96, max(16, Int((1.25 * assistDiameterPx).rounded())))
        let win = displayWindow()
        let bytes = renderCrop(pixels: pc.pixels, width: Int(pc.imageSize.width), height: Int(pc.imageSize.height), cx: x, cy: y, half: half,
                               lo: Double(win.lo), hi: Double(win.hi))
        return CoreMLEmbedding.embed(gray: bytes, size: 2 * half)
    }

    /// A decision was recorded for the open micrograph: learn from it.
    func assistObserve(_ c: Card, decision: String, key: String) {
        reranker.use(store: pc.store)
        reranker.observe(key: key, id: c.id, decision: decision, decoy: c.decoy, hand: assistHand(c.x, c.y), embedding: assistEmbedding(c.x, c.y))
    }

    /// Re-orders the cards still waiting (never the one on screen, never the decoys). With the assistant off the score order is restored.
    func assistReorder() {
        guard queue.count > 2, let key = pc.currentKey, !pc.pixels.isEmpty else { return }
        let rr = reranker
        if rr.mode == .off {
            guard assistReordered else { return }
            let scores: [Float?] = queue.map { $0.decoy ? nil : ($0.score ?? -.infinity) }
            let perm = Reranker.order(decoy: queue.map { $0.decoy }, p: scores, mode: .likely, exploreEvery: 0, seed: 0)
            applyOrder(perm.map { queue[$0].id }); assistReordered = false
            return
        }
        guard rr.model != nil else { return }
        let cards = Array(queue.prefix(rr.modelUsesEmbedding ? 120 : queue.count))      // embeddings are slower: only the next 120 cards
        let probs: [Float?] = cards.map { c in
            c.decoy ? nil : rr.probability(hand: assistHand(c.x, c.y), embedding: rr.modelUsesEmbedding ? assistEmbedding(c.x, c.y) : nil)
        }
        let perm = Reranker.order(decoy: cards.map { $0.decoy }, p: probs, mode: rr.mode, seed: stableHash(key) &+ UInt64(reviewed))
        applyOrder(perm.map { cards[$0].id })
        assistReordered = true
    }
}
