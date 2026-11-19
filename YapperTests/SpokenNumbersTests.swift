import Testing
import Foundation

/// Parakeet's words as heard, with what should be typed.
struct SpokenNumbersTests {
    private func w(_ s: String) -> String { SpokenNumbers.write(s) }

    @Test func smallNumbersStayWords() {
        #expect(w("Just water one plant.") == "Just water one plant.")
        #expect(w("the first room and the second") == "the first room and the second")
        #expect(w("sort them one by one") == "sort them one by one")
        #expect(w("One more thing.") == "One more thing.")
        #expect(w("the second one looks better") == "the second one looks better")
        #expect(w("Let's book a one on one meeting.") == "Let's book a one on one meeting.")
        #expect(w("after the first one hour, we stop") == "after the first one hour, we stop")
        #expect(w("we hit the five hour mark") == "we hit the five hour mark")
        #expect(w("cut one half off and then") == "cut one half off and then")
    }

    @Test func neverDropsWords() {
        #expect(w("two red cups and two blue plates") == "two red cups and two blue plates")
        #expect(w("we need two chairs and three tables.") == "we need two chairs and three tables.")
        #expect(w("Let's try a twenty on the left") == "Let's try a 20 on the left")
        #expect(w("wrap it in a single quote.") == "wrap it in a single quote.")
        #expect(w("type a tilde and a slash") == "type a tilde and a slash")
    }

    @Test func tenAndUpBecomeDigits() {
        #expect(w("if you count thirteen, it works") == "if you count 13, it works")
        #expect(w("The store opens forty-eight hours later") == "The store opens 48 hours later")
        #expect(w("The garden is at twenty-five or at twenty?") == "The garden is at 25 or at 20?")
        #expect(w("we have twenty five users") == "we have 25 users")
        #expect(w("in the past thirty days") == "in the past 30 days")
        #expect(w("version twelve") == "version 12")
        #expect(w("about two hundred") == "about 200")
        #expect(w("about two hundred and five") == "about 205")
        #expect(w("we ordered twenty five hundred bricks") == "we ordered 2500 bricks")
        #expect(w("it went past twelve thousand five hundred views") == "it went past 12,500 views")
        #expect(w("just set the a hundred. Then") == "just set the 100. Then")
        #expect(w("Let's go with a hundred, but") == "Let's go with 100, but")
        #expect(w("open the page hundred link") == "open the page 100 link")
        #expect(w("I think it said 300 hundred.") == "I think it said 300 hundred.")
    }

    @Test func unitsMakeFigures() {
        #expect(w("turn it up to a hundred percent") == "turn it up to 100%")
        #expect(w("up five percent") == "up 5%")
        #expect(w("it costs five dollars") == "it costs $5")
        #expect(w("about five thousand dollars a year") == "about $5000 a year")
        #expect(w("there's a hundred dollars on the card") == "there's $100 on the card")
        #expect(w("it was five dollars and fifty cents") == "it was $5.50")
        #expect(w("the laptop has eight gigabytes of memory") == "the laptop has 8 gigabytes of memory")
        #expect(w("meet at five o'clock") == "meet at 5:00")
    }

    @Test func decimals() {
        #expect(w("the score is a three point six four average") == "the score is a 3.64 average")
        #expect(w("bump it to one point five") == "bump it to 1.5")
        #expect(w("at one point I thought") == "at one point I thought")
    }

    @Test func digitCodes() {
        #expect(w("the code is three zero two, I think") == "the code is 302, I think")
        #expect(w("call four one five five five five") == "call 415555")
        #expect(w("press three five") == "press three five")
        #expect(w("one two three") == "one two three")
    }

    @Test func years() {
        #expect(w("maybe twenty twenty, twenty nineteen.") == "maybe 2020, 2019.")
        #expect(w("back in nineteen ninety") == "back in 1990")
        #expect(w("it went up five percent in two thousand twenty five") == "it went up 5% in 2025")
        #expect(w("since twenty oh five") == "since 2005")
    }

    @Test func ranges() {
        #expect(w("set the price at around ninety to one hundred. Then") == "set the price at around 90 to 100. Then")
        #expect(w("The shop is open nine thirty to two thirty.") == "The shop is open 9:30 to 2:30.")
        #expect(w("we're free from ten to four") == "we're free from 10 to 4")
        #expect(w("between five and ten people") == "between five and 10 people")
    }

    @Test func ordinals() {
        #expect(w("for the first thirty minutes of class") == "for the first 30 minutes of class")
        #expect(w("on the twenty first") == "on the 21st")
        #expect(w("the twelfth chapter") == "the 12th chapter")
    }

    @Test func numbersSaidSideBySideStayAsSaid() {
        #expect(w("I'm tied between three and five.") == "I'm tied between three and five.")
        #expect(w("I like four and eight the best.") == "I like four and eight the best.")
        #expect(w("order like six fifty five boxes each week") == "order like six fifty five boxes each week")
        #expect(w("lower it to forty nine ninety nine") == "lower it to forty nine ninety nine")
        #expect(w("put the shelf at one seventeen, or so") == "put the shelf at one seventeen, or so")
        #expect(w("go through each one one by one.") == "go through each one one by one.")
        #expect(w("I have four thirty dollar tickets") == "I have four thirty dollar tickets")
    }

    @Test func leavesTextWithoutNumbersAlone() {
        #expect(w("the code editor is open") == "the code editor is open")
        #expect(w("a  double  space") == "a  double  space")
        #expect(w("") == "")
    }
}

struct SpokenTimesDigitTests {
    @Test func aRoundHundredAfterAtIsAQuantity() {
        #expect(SpokenTimes.normalize("Let's set it at 100 first.") == "Let's set it at 100 first.")
        #expect(SpokenTimes.normalize("see you at 1130") == "see you at 11:30")
        #expect(SpokenTimes.normalize("at 100 pm") == "at 1:00 pm")
    }
}
