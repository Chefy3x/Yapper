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
