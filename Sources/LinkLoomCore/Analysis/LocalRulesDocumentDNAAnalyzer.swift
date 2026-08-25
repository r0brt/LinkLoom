import Foundation

public struct LocalRulesDocumentDNAAnalyzer: DocumentDNAAnalyzing {
    public static let schemaVersion = 1
    public static let analyzerIdentifier = "local-rules"
    public static let analyzerVersion = "1"
    private static let labelledReferencePattern = #"(?mi)^(Vertragsnummer|Rechnungsnummer|Policennummer|Schadennummer|Kundennummer|Zahlungsreferenz|Referenz):[ \t]*([A-Z0-9][A-Z0-9 ./-]*?)[ \t]*$"#

    public init() {}

    public func analyze(
        documentID: UUID,
        contentHash: String,
        extraction: StoredExtraction,
        analyzedAt: Date
    ) throws -> DocumentDNA {
        guard extraction.documentID == documentID else {
            throw DocumentDNAValidationError.invalidSnapshot
        }
        let pages = extraction.extraction.pages.sorted { $0.pageIndex < $1.pageIndex }
        var candidates = [Candidate]()
        candidates.append(try classification(in: pages))
        candidates += try people(in: pages)
        candidates += try organizations(in: pages)
        candidates += try dates(in: pages)
        candidates += try amounts(in: pages)
        candidates += try references(in: pages)

        return try DocumentDNA(
            documentID: documentID,
            schemaVersion: Self.schemaVersion,
            analyzerIdentifier: Self.analyzerIdentifier,
            analyzerVersion: Self.analyzerVersion,
            inputContentHash: contentHash,
            inputExtractionVersion: extraction.analysisVersion,
            findings: try collapsedFindings(candidates),
            analyzedAt: analyzedAt
        )
    }

    private func classification(in pages: [ExtractedPage]) throws -> Candidate {
        let rules: [ClassificationRule] = [
            ClassificationRule(type: .contract, pattern: #"\bPflegevertrag\b"#, score: 3),
            ClassificationRule(type: .contract, pattern: #"\bVertrag\b"#, score: 3),
            ClassificationRule(type: .invoice, pattern: #"\bRechnung\b"#, score: 3),
            ClassificationRule(
                type: .paymentConfirmation,
                pattern: #"\bZahlungsbestätigung\b"#,
                score: 3
            ),
            ClassificationRule(
                type: .insuranceStatement,
                pattern: #"\bLeistungsabrechnung\b"#,
                score: 3
            ),
            ClassificationRule(
                type: .medicalOrCareDocument,
                pattern: #"\b(?:Pflegedokumentation|Pflegebericht)\b"#,
                score: 3
            ),
            ClassificationRule(
                type: .powerOfAttorney,
                pattern: #"\bVollmacht\b"#,
                score: 3
            ),
            ClassificationRule(
                type: .correspondence,
                pattern: #"\bKorrespondenz\b"#,
                score: 3
            ),
        ]
        var scores = [DocumentType: Int]()
        var evidence = [DocumentType: DocumentDNAEvidence]()
        for rule in rules {
            for page in pages {
                guard let match = matches("(?i)" + rule.pattern, in: page.text).first else {
                    continue
                }
                scores[rule.type, default: 0] += rule.score
                let candidateEvidence = try makeEvidence(page: page, range: match.range)
                if let current = evidence[rule.type] {
                    if evidenceSort(candidateEvidence, current) {
                        evidence[rule.type] = candidateEvidence
                    }
                } else {
                    evidence[rule.type] = candidateEvidence
                }
                break
            }
        }
        let orderedScores = scores.sorted {
            if $0.value != $1.value {
                return $0.value > $1.value
            }
            return $0.key.rawValue < $1.key.rawValue
        }
        guard let winner = orderedScores.first,
              winner.value >= 2,
              orderedScores.dropFirst().first?.value != winner.value,
              let winnerEvidence = evidence[winner.key]
        else {
            return Candidate(
                kind: .documentType,
                qualifier: nil,
                displayValue: "",
                normalizedValue: DocumentType.unknown.rawValue,
                secondaryNormalizedValue: nil,
                confidence: 0,
                evidence: []
            )
        }
        return Candidate(
            kind: .documentType,
            qualifier: nil,
            displayValue: winnerEvidence.exactText,
            normalizedValue: winner.key.rawValue,
            secondaryNormalizedValue: nil,
            confidence: 1,
            evidence: [winnerEvidence]
        )
    }

    private func people(in pages: [ExtractedPage]) throws -> [Candidate] {
        let pattern = #"(?mi)^(Bewohnerin|Versicherte Person|Kontoinhaberin|Rechnung an|Vollmachtgeberin|Bevollmächtigte):[ \t]*([^\r\n]+?)[ \t]*$"#
        let roles = [
            "bewohnerin": "resident",
            "versicherte person": "insuredPerson",
            "kontoinhaberin": "accountHolder",
            "rechnung an": "invoiceRecipient",
            "vollmachtgeberin": "grantor",
            "bevollmächtigte": "authorizedPerson",
        ]
        return try labelledCandidates(
            in: pages,
            pattern: pattern,
            kind: .person,
            roles: roles,
            valueGroup: 2,
            normalizer: normalizeName
        )
    }

    private func organizations(in pages: [ExtractedPage]) throws -> [Candidate] {
        let labelledPattern = #"(?mi)^(Anbieter|Ausstellerin|Versicherer|Zahlungsempfängerin|Behörde):[ \t]*([^\r\n]+?)[ \t]*$"#
        let roles = [
            "anbieter": "provider",
            "ausstellerin": "issuer",
            "versicherer": "insurer",
            "zahlungsempfängerin": "payee",
            "behörde": "authority",
        ]
        var candidates = try labelledCandidates(
            in: pages,
            pattern: labelledPattern,
            kind: .organization,
            roles: roles,
            valueGroup: 2,
            normalizer: normalizeName
        )
        let legalFormPattern = #"(?mi)^((?:Stiftung[ \t]+[^\r\n:]+|[^\r\n:]+[ \t]+(?:AG|GmbH)))[ \t]*$"#
        for page in pages {
            let source = page.text as NSString
            for match in matches(legalFormPattern, in: page.text) {
                let range = match.range(at: 1)
                let display = source.substring(with: range)
                candidates.append(Candidate(
                    kind: .organization,
                    qualifier: nil,
                    displayValue: display,
                    normalizedValue: normalizeName(display),
                    secondaryNormalizedValue: nil,
                    confidence: 0.9,
                    evidence: [try makeEvidence(page: page, range: range)]
                ))
            }
        }
        return candidates
    }

    private func dates(in pages: [ExtractedPage]) throws -> [Candidate] {
        let token = #"(?:[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{2}\.[0-9]{2}\.[0-9]{4})"#
        let labelledPattern = #"(?mi)^(Rechnungsdatum|Ausstellungsdatum|Vertragsdatum|Fälligkeitsdatum|Leistungsdatum|Leistungszeitraum|Buchungsdatum|Geburtsdatum|Datum):[ \t]*("#
            + token
            + #")(?:[ \t]*[-–][ \t]*("#
            + token
            + #"))?[ \t]*$"#
        let roles: [String: DocumentDNADateRole] = [
            "rechnungsdatum": .issueDate,
            "ausstellungsdatum": .issueDate,
            "vertragsdatum": .issueDate,
            "fälligkeitsdatum": .dueDate,
            "leistungsdatum": .serviceDate,
            "leistungszeitraum": .servicePeriod,
            "buchungsdatum": .bookingDate,
            "geburtsdatum": .birthDate,
            "datum": .unknown,
        ]
        var candidates = [Candidate]()
        var claimedRanges = [Int: [NSRange]]()
        for page in pages {
            for match in matches(Self.labelledReferencePattern, in: page.text) {
                claimedRanges[page.pageIndex, default: []].append(match.range(at: 2))
            }
        }
        for page in pages {
            let source = page.text as NSString
            for match in matches(labelledPattern, in: page.text) {
                let startRange = match.range(at: 2)
                let endRange = match.range(at: 3)
                let startText = source.substring(with: startRange)
                guard let normalizedStart = normalizeDate(startText) else {
                    continue
                }
                let normalizedEnd: String?
                let evidenceRange: NSRange
                if endRange.location == NSNotFound {
                    normalizedEnd = nil
                    evidenceRange = startRange
                } else {
                    let endText = source.substring(with: endRange)
                    guard let parsedEnd = normalizeDate(endText),
                          normalizedStart <= parsedEnd
                    else {
                        continue
                    }
                    normalizedEnd = parsedEnd
                    evidenceRange = NSUnionRange(startRange, endRange)
                }
                claimedRanges[page.pageIndex, default: []].append(evidenceRange)
                let label = source.substring(with: match.range(at: 1))
                    .lowercased(with: Locale(identifier: "en_US_POSIX"))
                candidates.append(Candidate(
                    kind: .date,
                    qualifier: roles[label]!.rawValue,
                    displayValue: source.substring(with: evidenceRange),
                    normalizedValue: normalizedStart,
                    secondaryNormalizedValue: normalizedEnd,
                    confidence: 1,
                    evidence: [try makeEvidence(page: page, range: evidenceRange)]
                ))
            }
        }
        let unlabelledPattern = #"(?<![0-9])"# + token + #"(?![0-9])"#
        for page in pages {
            let source = page.text as NSString
            for match in matches(unlabelledPattern, in: page.text) {
                guard !(claimedRanges[page.pageIndex] ?? []).contains(where: {
                    NSIntersectionRange($0, match.range).length > 0
                }) else {
                    continue
                }
                let display = source.substring(with: match.range)
                guard let normalized = normalizeDate(display) else {
                    continue
                }
                candidates.append(Candidate(
                    kind: .date,
                    qualifier: DocumentDNADateRole.unknown.rawValue,
                    displayValue: display,
                    normalizedValue: normalized,
                    secondaryNormalizedValue: nil,
                    confidence: 0.8,
                    evidence: [try makeEvidence(page: page, range: match.range)]
                ))
            }
        }
        return candidates
    }

    private func amounts(in pages: [ExtractedPage]) throws -> [Candidate] {
        let pattern = #"(?i)(?:(CHF|Fr\.|EUR)[ \t]*([0-9](?:[0-9'’.,  ]*[0-9])?)|([0-9](?:[0-9'’.,  ]*[0-9])?)[ \t]*(CHF|Fr\.|EUR))"#
        var candidates = [Candidate]()
        for page in pages {
            let source = page.text as NSString
            for match in matches(pattern, in: page.text) {
                let currencyRange = match.range(at: 1).location == NSNotFound
                    ? match.range(at: 4)
                    : match.range(at: 1)
                let valueRange = match.range(at: 2).location == NSNotFound
                    ? match.range(at: 3)
                    : match.range(at: 2)
                let currencyText = source.substring(with: currencyRange)
                let valueText = source.substring(with: valueRange)
                guard let normalized = normalizeAmount(valueText) else {
                    continue
                }
                candidates.append(Candidate(
                    kind: .monetaryAmount,
                    qualifier: currencyText.lowercased().hasPrefix("fr") ? "CHF" : currencyText.uppercased(),
                    displayValue: source.substring(with: match.range),
                    normalizedValue: normalized,
                    secondaryNormalizedValue: nil,
                    confidence: 1,
                    evidence: [try makeEvidence(page: page, range: match.range)]
                ))
            }
        }
        return candidates
    }

    private func references(in pages: [ExtractedPage]) throws -> [Candidate] {
        let kinds: [String: DocumentDNAReferenceNumberKind] = [
            "vertragsnummer": .contractNumber,
            "rechnungsnummer": .invoiceNumber,
            "policennummer": .policyNumber,
            "schadennummer": .claimNumber,
            "kundennummer": .customerNumber,
            "zahlungsreferenz": .paymentReference,
            "referenz": .other,
        ]
        var candidates = [Candidate]()
        for page in pages {
            let source = page.text as NSString
            for match in matches(Self.labelledReferencePattern, in: page.text) {
                let label = source.substring(with: match.range(at: 1))
                    .lowercased(with: Locale(identifier: "en_US_POSIX"))
                let valueRange = match.range(at: 2)
                let display = source.substring(with: valueRange)
                candidates.append(Candidate(
                    kind: .referenceNumber,
                    qualifier: kinds[label]!.rawValue,
                    displayValue: display,
                    normalizedValue: display
                        .filter { !$0.isWhitespace }
                        .uppercased(with: Locale(identifier: "en_US_POSIX")),
                    secondaryNormalizedValue: nil,
                    confidence: 1,
                    evidence: [try makeEvidence(page: page, range: valueRange)]
                ))
            }
        }
        return candidates
    }

    private func labelledCandidates(
        in pages: [ExtractedPage],
        pattern: String,
        kind: DocumentDNAFindingKind,
        roles: [String: String],
        valueGroup: Int,
        normalizer: (String) -> String
    ) throws -> [Candidate] {
        var candidates = [Candidate]()
        for page in pages {
            let source = page.text as NSString
            for match in matches(pattern, in: page.text) {
                let label = source.substring(with: match.range(at: 1))
                    .lowercased(with: Locale(identifier: "en_US_POSIX"))
                let valueRange = match.range(at: valueGroup)
                let display = source.substring(with: valueRange)
                candidates.append(Candidate(
                    kind: kind,
                    qualifier: roles[label],
                    displayValue: display,
                    normalizedValue: normalizer(display),
                    secondaryNormalizedValue: nil,
                    confidence: 1,
                    evidence: [try makeEvidence(page: page, range: valueRange)]
                ))
            }
        }
        return candidates
    }

    private func collapsedFindings(_ candidates: [Candidate]) throws -> [DocumentDNAFinding] {
        let sorted = candidates.sorted(by: candidateSort)
        var order = [CandidateKey]()
        var byKey = [CandidateKey: Candidate]()
        for candidate in sorted {
            let key = CandidateKey(candidate)
            if var existing = byKey[key] {
                for item in candidate.evidence where !existing.evidence.contains(item) {
                    existing.evidence.append(item)
                }
                existing.evidence.sort(by: evidenceSort)
                byKey[key] = existing
            } else {
                order.append(key)
                byKey[key] = candidate
            }
        }
        return try order.map { key in
            let candidate = byKey[key]!
            return try DocumentDNAFinding(
                kind: candidate.kind,
                qualifier: candidate.qualifier,
                displayValue: candidate.displayValue,
                normalizedValue: candidate.normalizedValue,
                secondaryNormalizedValue: candidate.secondaryNormalizedValue,
                confidence: candidate.confidence,
                evidence: candidate.evidence
            )
        }
    }

    private func makeEvidence(
        page: ExtractedPage,
        range: NSRange
    ) throws -> DocumentDNAEvidence {
        let source = page.text as NSString
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length > 0,
              NSMaxRange(range) <= source.length
        else {
            throw DocumentDNAValidationError.invalidEvidence
        }
        let regionRanges = page.regions.enumerated().map { index, region in
            let precedingLength = page.regions[..<index]
                .reduce(0) { $0 + ($1.text as NSString).length + 1 }
            return NSRange(location: precedingLength, length: (region.text as NSString).length)
        }
        let indexes = regionRanges.enumerated().compactMap { index, regionRange in
            NSIntersectionRange(range, regionRange).length > 0 ? index : nil
        }
        return try DocumentDNAEvidence(
            pageIndex: page.pageIndex,
            startUTF16: range.location,
            lengthUTF16: range.length,
            exactText: source.substring(with: range),
            ocrRegionIndexes: indexes
        )
    }

    private func matches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        let expression = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: (text as NSString).length)
        return expression.matches(in: text, range: range)
    }

    private func normalizeName(_ value: String) -> String {
        value
            .precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private func normalizeDate(_ value: String) -> String? {
        let parts: [Substring]
        if value.contains(".") {
            let dotted = value.split(separator: ".", omittingEmptySubsequences: false)
            guard dotted.count == 3 else { return nil }
            parts = [dotted[2], dotted[1], dotted[0]]
        } else {
            parts = value.split(separator: "-", omittingEmptySubsequences: false)
        }
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        )
        guard let date = calendar.date(from: components) else {
            return nil
        }
        let checked = calendar.dateComponents([.year, .month, .day], from: date)
        guard checked.year == year, checked.month == month, checked.day == day else {
            return nil
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private func normalizeAmount(_ value: String) -> String? {
        let normalizedSpaces = String(value.map { $0.isWhitespace ? " " : $0 })
        let canonical: String
        if matchesEntire(#"[0-9]+(?:[.,][0-9]{1,2})?"#, value: normalizedSpaces) {
            canonical = normalizedSpaces.replacingOccurrences(of: ",", with: ".")
        } else if matchesEntire(
            #"[0-9]{1,3}(?:['’ ][0-9]{3})+(?:[.,][0-9]{1,2})?"#,
            value: normalizedSpaces
        ) {
            canonical = normalizedSpaces
                .filter { $0 != "'" && $0 != "’" && !$0.isWhitespace }
                .replacingOccurrences(of: ",", with: ".")
        } else if matchesEntire(
            #"[0-9]{1,3}(?:\.[0-9]{3})+(?:,[0-9]{1,2})?"#,
            value: normalizedSpaces
        ) {
            canonical = normalizedSpaces
                .replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: ",", with: ".")
        } else if matchesEntire(
            #"[0-9]{1,3}(?:,[0-9]{3})+(?:\.[0-9]{1,2})?"#,
            value: normalizedSpaces
        ) {
            canonical = normalizedSpaces.replacingOccurrences(of: ",", with: "")
        } else {
            return nil
        }
        guard let decimal = Decimal(
            string: canonical,
            locale: Locale(identifier: "en_US_POSIX")
        ) else {
            return nil
        }
        return NSDecimalNumber(decimal: decimal).stringValue
    }

    private func matchesEntire(_ pattern: String, value: String) -> Bool {
        value.range(
            of: "^(?:" + pattern + ")$",
            options: .regularExpression
        ) != nil
    }

    private func candidateSort(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        let left = lhs.evidence.first
        let right = rhs.evidence.first
        let leftPage = left?.pageIndex ?? Int.max
        let rightPage = right?.pageIndex ?? Int.max
        if leftPage != rightPage { return leftPage < rightPage }
        let leftStart = left?.startUTF16 ?? Int.max
        let rightStart = right?.startUTF16 ?? Int.max
        if leftStart != rightStart { return leftStart < rightStart }
        if lhs.kind.rawValue != rhs.kind.rawValue {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        if lhs.qualifier != rhs.qualifier {
            return (lhs.qualifier ?? "") < (rhs.qualifier ?? "")
        }
        return lhs.normalizedValue < rhs.normalizedValue
    }

    private func evidenceSort(
        _ lhs: DocumentDNAEvidence,
        _ rhs: DocumentDNAEvidence
    ) -> Bool {
        if lhs.pageIndex != rhs.pageIndex { return lhs.pageIndex < rhs.pageIndex }
        if lhs.startUTF16 != rhs.startUTF16 { return lhs.startUTF16 < rhs.startUTF16 }
        if lhs.lengthUTF16 != rhs.lengthUTF16 { return lhs.lengthUTF16 < rhs.lengthUTF16 }
        return lhs.exactText < rhs.exactText
    }
}

private struct ClassificationRule {
    let type: DocumentType
    let pattern: String
    let score: Int
}

private struct Candidate {
    let kind: DocumentDNAFindingKind
    let qualifier: String?
    let displayValue: String
    let normalizedValue: String
    let secondaryNormalizedValue: String?
    let confidence: Double
    var evidence: [DocumentDNAEvidence]
}

private struct CandidateKey: Hashable {
    let kind: DocumentDNAFindingKind
    let qualifier: String?
    let normalizedValue: String
    let secondaryNormalizedValue: String?

    init(_ candidate: Candidate) {
        kind = candidate.kind
        qualifier = candidate.qualifier
        normalizedValue = candidate.normalizedValue
        secondaryNormalizedValue = candidate.secondaryNormalizedValue
    }
}
