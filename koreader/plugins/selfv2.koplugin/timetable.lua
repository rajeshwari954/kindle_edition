-- Weekly lecture timetable (F.Y.LL.B. Sem I, Division E). Keys: 1 = Sunday … 7 = Saturday.
-- Each lecture: { subject (as in Notion), short label, start time, faculty }.
-- Only Tuesday is filled in so far; send Claude the rest and it will add them.
return {
    [3] = {
        { "Law of Contract", "Contract", "7:30", "Mr. Shivam Yadav" },
        { "Torts MVA & CPA", "Torts", "8:30", "Ms. Mayuri Taware" },
        { "Constitutional Law-I", "Const. Law", "9:45", "Ms. Meghna Patil" },
        { "BNS", "BNS", "10:45", "Ms. Mayuri Taware" },
        { "Mentoring", "Mentoring", "12:00", nil },
    },
}
