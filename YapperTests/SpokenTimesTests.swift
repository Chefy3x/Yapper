import Testing

struct SpokenTimesTests {
    private func t(_ s: String) -> String { SpokenTimes.normalize(s) }

    @Test func timesAfterATimeWord() {
        #expect(t("Let's meet at 401.") == "Let's meet at 4:01.")
        #expect(t("Let's meet at 4.01 tomorrow.") == "Let's meet at 4:01 tomorrow.")
        #expect(t("around 1130 works") == "around 11:30 works")
        #expect(t("Can you be there by 4 15?") == "Can you be there by 4:15?")
        #expect(t("at like 430") == "at like 4:30")
        #expect(t("until 1205") == "until 12:05")
    }

    @Test func timesWithAmPm() {
        #expect(t("The call is 401 pm.") == "The call is 4:01 pm.")
        #expect(t("It starts 4.30 p.m. sharp") == "It starts 4:30 p.m. sharp")
        #expect(t("set it for 730am") == "set it for 7:30 am")
    }

    @Test func rangeEnds() {
        #expect(t("from 1130 to 1230") == "from 11:30 to 12:30")
        #expect(t("at 4 or 430") == "at 4 or 4:30")
        #expect(t("between 9:15 and 945") == "between 9:15 and 9:45")
    }

    @Test func leavesQuantitiesCodesAndAddressesAlone() {
        #expect(t("Put it in my 401k.") == "Put it in my 401k.")
        #expect(t("We got 401 errors") == "We got 401 errors")
        #expect(t("at 430 people per day") == "at 430 people per day")
        #expect(t("It returned error 401 at login") == "It returned error 401 at login")
        #expect(t("Meet me at 401 Main Street") == "Meet me at 401 Main Street")
        #expect(t("from 2024 onwards") == "from 2024 onwards")
        #expect(t("by 1.25x") == "by 1.25x")
        #expect(t("at 4.5 percent") == "at 4.5 percent")
        #expect(t("version 4.01 is out") == "version 4.01 is out")
        #expect(t("at 4:01 already") == "at 4:01 already")
        #expect(t("at 4 o'clock") == "at 4 o'clock")
        #expect(t("no numbers here") == "no numbers here")
    }
}

struct SpokenTimeWordsTests {
    private func t(_ s: String) -> String { SpokenTimes.normalizeSpoken(s) }

    @Test func timesInWords() {
        #expect(t("The train leaves at twenty one oh four.") == "The train leaves at 21:04.")
        #expect(t("let's meet at four thirty") == "let's meet at 4:30")
        #expect(t("call me around eleven fifteen") == "call me around 11:15")
        #expect(t("it starts four forty five pm") == "it starts 4:45 pm")
        #expect(t("at like seven oh five") == "at like 7:05")
    }

    @Test func leavesOtherNumbersAlone() {
        #expect(t("at four") == "at four")
        #expect(t("I have four thirty dollar tickets") == "I have four thirty dollar tickets")
        #expect(t("at four thirty people") == "at four thirty people")
        #expect(t("one two three") == "one two three")
    }
}

struct NumberStyleTests {
    private func r(_ spoken: String, _ written: String) -> String { NumberStyle.restrain(spoken: spoken, written: written) }

    @Test func smallNumbersStayWords() {
        #expect(r("Just water one plant.", "Just water 1 plant.") == "Just water one plant.")
        #expect(r("the first room and the second", "the 1st room and the 2nd") == "the first room and the second")
        #expect(r("sort them one by one", "sort them 1 by 1") == "sort them one by one")
        #expect(r("One more thing.", "1 more thing.") == "One more thing.")
        #expect(r("the second one looks better", "the 2nd 1 looks better") == "the second one looks better")
    }

    @Test func separateNumbersStaySeparate() {
        #expect(r("I'm tied between three and five.", "I'm tied between 35.") == "I'm tied between three and five.")
        #expect(r("I like four and eight the best.", "I like 48 the best.") == "I like four and eight the best.")
        #expect(r("the number four and probably number two", "the number 4 probably number 2")
                == "the number four and probably number two")
        #expect(r("press three five", "press 35") == "press three five")
        #expect(r("about two hundred and five", "about 205") == "about 205")
        #expect(r("it was five dollars and fifty cents", "it was $5.50") == "it was $5.50")
    }

    @Test func biggerOnesKeepTheirDigits() {
        #expect(r("we have twenty five users", "we have 25 users") == "we have 25 users")
        #expect(r("it costs five dollars", "it costs $5") == "it costs $5")
        #expect(r("up five percent", "up 5%") == "up 5%")
        #expect(r("about two hundred", "about 200") == "about 200")
        #expect(r("version twelve", "version 12") == "version 12")
    }
}
