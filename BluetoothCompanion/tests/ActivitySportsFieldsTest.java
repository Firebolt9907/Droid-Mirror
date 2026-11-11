/** Resource identity survives nested ESPN containers without guessing from image position. */
public final class ActivitySportsFieldsTest {
    public static void main(String[] args) throws Exception {
        Class<?> cls=Class.forName("app.droidmirror.bluetooth.bridge.ActivitySportsFields");
        Object parser=cls.getField("INSTANCE").get(null);
        var team=cls.getMethod("team",String.class,int.class);
        var field=cls.getMethod("field",String.class,boolean.class,boolean.class);
        check(team.invoke(parser,"team_one_container",0).equals(1));
        check(team.invoke(parser,"iv_team_logo",1).equals(1));
        check(team.invoke(parser,"away_team_logo",1).equals(2));
        check(team.invoke(parser,"score_one",0).equals(1));
        check(team.invoke(parser,"score_two",0).equals(2));
        check(field.invoke(parser,"iv_team_logo",true,false).equals("logo"));
        check(field.invoke(parser,"team_icon",true,false).equals("logo"));
        check(field.invoke(parser,"home_score",false,true).equals("score"));
        check(field.invoke(parser,"team_two_name",false,true).equals("name"));
        check(field.invoke(parser,"note_avatar",true,false)==null);
        var indicator=cls.getMethod("indicator",String.class,String.class);
        check(indicator.invoke(parser,"iv_team_one_possession", "").equals("possession"));
        check(indicator.invoke(parser,"serve_indicator", "").equals("serving"));
        check(indicator.invoke(parser,"batting_team", "").equals("batting"));
        check(indicator.invoke(parser,"", "Has the ball").equals("possession"));
        check(indicator.invoke(parser,"", "Serving").equals("serving"));
        check(indicator.invoke(parser,"", "At bat").equals("batting"));
        check(indicator.invoke(parser,"time_of_possession", "")==null);
        check(indicator.invoke(parser,"possession_percentage", "")==null);
        check(indicator.invoke(parser,"batting_average", "")==null);
        check(indicator.invoke(parser,"game_status", "1st & 10 at ND 32")==null);
        check(team.invoke(parser,"iv_possession_one",0).equals(1));
        check(team.invoke(parser,"away_possession",0).equals(2));
        check(team.invoke(parser,"home_serving_indicator",0).equals(1));
        check(team.invoke(parser,"batting_two",0).equals(2));
        check(field.invoke(parser,"tv_game_status",false,true).equals("statusPrimary"));
        check(field.invoke(parser,"status_primary",false,true).equals("statusPrimary"));
        check(field.invoke(parser,"tv_pre_status_line_one",false,true).equals("statusPrimary"));
        check(field.invoke(parser,"tv_status_secondary",false,true).equals("statusSecondary"));
        check(field.invoke(parser,"iv_bases",true,false).equals("bases"));
        check(field.invoke(parser,"base_occupancy",true,false).equals("bases"));
        check(field.invoke(parser,"team_one_set_score",false,true).equals("setScore"));
        check(field.invoke(parser,"team_two_score_set_2",false,true).equals("setScore"));
        check(field.invoke(parser,"tv_network_chip",false,true).equals("broadcast"));
        check(field.invoke(parser,"iv_live_team_one_indicator",true,false)==null);
        check(indicator.invoke(parser,"winner_indicator", "Has the ball")==null);
        check(indicator.invoke(parser,"team_two_indicator", "Iowa is serving").equals("serving"));
        var gameClock=cls.getMethod("gameClock",String.class);
        check(gameClock.invoke(parser,"period_clock").equals(true));
        check(gameClock.invoke(parser,"game_status").equals(true));
        check(gameClock.invoke(parser,"play_clock").equals(false));
        check(gameClock.invoke(parser,"shot_clock").equals(false));
        var setScore=cls.getMethod("setScore",String.class);
        check(setScore.invoke(parser,"set_1_score").equals(true));
        check(setScore.invoke(parser,"reset_score").equals(false));
        check(setScore.invoke(parser,"team_one_score").equals(false));
        check(indicator.invoke(parser,"home_server", "").equals("serving"));
        check(indicator.invoke(parser,"home_batting", "").equals("batting"));
        check(indicator.invoke(parser,"team_one_stat", "Possession 58%")==null);
        check(indicator.invoke(parser,"team_one_stat", "Possession 02:30")==null);
        System.out.println("PASS: ESPN team resource identities and logo/score/name roles");
    }
    static void check(boolean value) { if(!value) throw new AssertionError(); }
}
