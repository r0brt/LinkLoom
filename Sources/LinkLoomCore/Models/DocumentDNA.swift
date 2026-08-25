import Foundation

public enum DocumentDNAFindingKind: String, Codable, CaseIterable, Sendable {
    case documentType
    case person
    case organization
    case date
    case monetaryAmount
    case referenceNumber
}

public enum DocumentType: String, Codable, CaseIterable, Sendable {
    case contract
    case invoice
    case paymentConfirmation
    case insuranceStatement
    case medicalOrCareDocument
    case powerOfAttorney
    case correspondence
    case unknown
}

public enum DocumentDNADateRole: String, Codable, CaseIterable, Sendable {
    case issueDate
    case dueDate
    case serviceDate
    case servicePeriod
    case bookingDate
    case birthDate
    case unknown
}

public enum DocumentDNAReferenceNumberKind: String, Codable, CaseIterable, Sendable {
    case contractNumber
    case invoiceNumber
    case policyNumber
    case claimNumber
    case customerNumber
    case paymentReference
    case other
}

public enum DocumentDNAValidationError: Error, Equatable {
    case invalidSnapshot
    case invalidFinding
    case invalidEvidence
}

public struct DocumentDNAEvidence: Codable, Sendable, Equatable {
    public let pageIndex: Int
    public let startUTF16: Int
    public let lengthUTF16: Int
    public let exactText: String
    public let ocrRegionIndexes: [Int]

    public init(
        pageIndex: Int,
        startUTF16: Int,
        lengthUTF16: Int,
        exactText: String,
        ocrRegionIndexes: [Int]
    ) throws {
        guard pageIndex >= 0,
              startUTF16 >= 0,
              lengthUTF16 > 0,
              !exactText.isEmpty,
              exactText.utf16.count == lengthUTF16,
              ocrRegionIndexes.allSatisfy({ $0 >= 0 }),
              ocrRegionIndexes == Array(Set(ocrRegionIndexes)).sorted()
        else {
            throw DocumentDNAValidationError.invalidEvidence
        }
        self.pageIndex = pageIndex
        self.startUTF16 = startUTF16
        self.lengthUTF16 = lengthUTF16
        self.exactText = exactText
        self.ocrRegionIndexes = ocrRegionIndexes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            pageIndex: container.decode(Int.self, forKey: .pageIndex),
            startUTF16: container.decode(Int.self, forKey: .startUTF16),
            lengthUTF16: container.decode(Int.self, forKey: .lengthUTF16),
            exactText: container.decode(String.self, forKey: .exactText),
            ocrRegionIndexes: container.decode([Int].self, forKey: .ocrRegionIndexes)
        )
    }
}

public struct DocumentDNAFinding: Codable, Sendable, Equatable {
    public let kind: DocumentDNAFindingKind
    public let qualifier: String?
    public let displayValue: String
    public let normalizedValue: String
    public let secondaryNormalizedValue: String?
    public let confidence: Double
    public let evidence: [DocumentDNAEvidence]

    public init(
        kind: DocumentDNAFindingKind,
        qualifier: String?,
        displayValue: String,
        normalizedValue: String,
        secondaryNormalizedValue: String?,
        confidence: Double,
        evidence: [DocumentDNAEvidence]
    ) throws {
        guard confidence.isFinite,
              (0...1).contains(confidence),
              Self.isValid(
                  kind: kind,
                  qualifier: qualifier,
                  displayValue: displayValue,
                  normalizedValue: normalizedValue,
                  secondaryNormalizedValue: secondaryNormalizedValue,
                  confidence: confidence,
                  evidence: evidence
              )
        else {
            throw DocumentDNAValidationError.invalidFinding
        }
        self.kind = kind
        self.qualifier = qualifier
        self.displayValue = displayValue
        self.normalizedValue = normalizedValue
        self.secondaryNormalizedValue = secondaryNormalizedValue
        self.confidence = confidence
        self.evidence = evidence
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(DocumentDNAFindingKind.self, forKey: .kind),
            qualifier: container.decodeIfPresent(String.self, forKey: .qualifier),
            displayValue: container.decode(String.self, forKey: .displayValue),
            normalizedValue: container.decode(String.self, forKey: .normalizedValue),
            secondaryNormalizedValue: container.decodeIfPresent(
                String.self,
                forKey: .secondaryNormalizedValue
            ),
            confidence: container.decode(Double.self, forKey: .confidence),
            evidence: container.decode([DocumentDNAEvidence].self, forKey: .evidence)
        )
    }

    private static func isValid(
        kind: DocumentDNAFindingKind,
        qualifier: String?,
        displayValue: String,
        normalizedValue: String,
        secondaryNormalizedValue: String?,
        confidence: Double,
        evidence: [DocumentDNAEvidence]
    ) -> Bool {
        if kind == .documentType,
           normalizedValue == DocumentType.unknown.rawValue {
            return qualifier == nil
                && displayValue.isEmpty
                && secondaryNormalizedValue == nil
                && confidence == 0
                && evidence.isEmpty
        }
        guard !displayValue.isEmpty,
              isNonBlank(normalizedValue),
              !evidence.isEmpty
        else {
            return false
        }

        switch kind {
        case .documentType:
            return qualifier == nil
                && secondaryNormalizedValue == nil
                && DocumentType(rawValue: normalizedValue) != nil
        case .person, .organization:
            return qualifier.map(isNonBlank) ?? true
                && secondaryNormalizedValue == nil
        case .date:
            return qualifier.flatMap(DocumentDNADateRole.init(rawValue:)) != nil
                || qualifier == nil
                ? isValidDateRange(
                    start: normalizedValue,
                    end: secondaryNormalizedValue
                )
                : false
        case .monetaryAmount:
            return isValidCurrency(qualifier)
                && secondaryNormalizedValue == nil
                && isCanonicalDecimal(normalizedValue)
        case .referenceNumber:
            return qualifier.flatMap(DocumentDNAReferenceNumberKind.init(rawValue:)) != nil
                && secondaryNormalizedValue == nil
        }
    }

    private static func isNonBlank(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isValidCurrency(_ value: String?) -> Bool {
        guard let value else { return false }
        if value == "unknown" {
            return true
        }
        return Locale.Currency(value).isISOCurrency
    }

    private static func isCanonicalDecimal(_ value: String) -> Bool {
        guard value.range(
            of: #"^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?$"#,
            options: .regularExpression
        ) != nil else {
            return false
        }
        return Decimal(
            string: value,
            locale: Locale(identifier: "en_US_POSIX")
        ) != nil
    }

    private static func isValidDateRange(start: String, end: String?) -> Bool {
        guard let startComponents = civilDateComponents(start) else {
            return false
        }
        guard let end else {
            return true
        }
        guard let endComponents = civilDateComponents(end) else {
            return false
        }
        let startTuple = (startComponents.year!, startComponents.month!, startComponents.day!)
        let endTuple = (endComponents.year!, endComponents.month!, endComponents.day!)
        return startTuple <= endTuple
    }

    private static func civilDateComponents(_ value: String) -> DateComponents? {
        guard let match = value.wholeMatch(of: /([0-9]{4})-([0-9]{2})-([0-9]{2})/),
              let year = Int(match.1),
              let month = Int(match.2),
              let day = Int(match.3)
        else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else {
            return nil
        }
        let checked = calendar.dateComponents([.year, .month, .day], from: date)
        return checked.year == year && checked.month == month && checked.day == day
            ? checked
            : nil
    }
}

public struct DocumentDNA: Codable, Sendable, Equatable {
    public let documentID: UUID
    public let schemaVersion: Int
    public let analyzerIdentifier: String
    public let analyzerVersion: String
    public let inputContentHash: String
    public let inputExtractionVersion: String
    public let findings: [DocumentDNAFinding]
    public let analyzedAt: Date

    public init(
        documentID: UUID,
        schemaVersion: Int,
        analyzerIdentifier: String,
        analyzerVersion: String,
        inputContentHash: String,
        inputExtractionVersion: String,
        findings: [DocumentDNAFinding],
        analyzedAt: Date
    ) throws {
        guard schemaVersion > 0,
              Self.isNonBlank(analyzerIdentifier),
              Self.isNonBlank(analyzerVersion),
              Self.isNonBlank(inputContentHash),
              Self.isNonBlank(inputExtractionVersion),
              findings.count(where: { $0.kind == .documentType }) == 1
        else {
            throw DocumentDNAValidationError.invalidSnapshot
        }
        self.documentID = documentID
        self.schemaVersion = schemaVersion
        self.analyzerIdentifier = analyzerIdentifier
        self.analyzerVersion = analyzerVersion
        self.inputContentHash = inputContentHash
        self.inputExtractionVersion = inputExtractionVersion
        self.findings = findings
        self.analyzedAt = analyzedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            documentID: container.decode(UUID.self, forKey: .documentID),
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            analyzerIdentifier: container.decode(String.self, forKey: .analyzerIdentifier),
            analyzerVersion: container.decode(String.self, forKey: .analyzerVersion),
            inputContentHash: container.decode(String.self, forKey: .inputContentHash),
            inputExtractionVersion: container.decode(
                String.self,
                forKey: .inputExtractionVersion
            ),
            findings: container.decode([DocumentDNAFinding].self, forKey: .findings),
            analyzedAt: container.decode(Date.self, forKey: .analyzedAt)
        )
    }

    private static func isNonBlank(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
