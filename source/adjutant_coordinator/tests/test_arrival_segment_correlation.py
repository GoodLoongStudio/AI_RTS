import unittest
from types import SimpleNamespace

from adjutant_coordinator.graph import nodes
from adjutant_coordinator.graph.graph import _cleaned
from adjutant_coordinator.graph.state import AdjutantGraphState


class ArrivalSegmentCorrelationTest(unittest.TestCase):
    def _state(self):
        return {'match_id':'arrival-probe','player_id':'Player_0','server_tick':1000,
                'active_intents':[], 'routes':{}, 'active_tasks':{}}

    def _intent(self, issued, goal):
        return {'intent_id':'hop-%s' % issued,'issued_tick':issued,'action':'scout',
                'state':'active','unit_ids':['Drone'], 'target':{'pos':goal}}

    def _event(self, seq, tick, goal):
        return {'seq':seq,'server_tick':tick,'unit':'Drone','kind':'arrival','target':goal}

    def _consume(self, state, event):
        nodes._consume_fast_events(state, SimpleNamespace(observation={'fast_events':[event]}))

    def _roundtrip(self, state):
        return AdjutantGraphState.from_dict(_cleaned(AdjutantGraphState.from_dict(state).to_dict())).to_dict()

    def test_duplicate_after_checkpoint_cannot_complete_or_stamp_new_hop(self):
        state=self._state(); state['active_intents']=[self._intent(990,[17.5,17.5])]
        self._consume(state,self._event(1,1000,[17.5,17.5]))
        state=self._roundtrip(state)
        state['active_intents']=[self._intent(1001,[30,17.5])]
        state['routes']={'Drone':{'ok':True,'last_replan_tick':1001,'relay_point':[30,17.5]}}
        self._consume(state,self._event(2,1002,[17.5,17.5]))
        self.assertEqual(state['active_intents'][0]['state'],'active')
        self.assertNotIn('effective_tick',state['active_intents'][0])
        self.assertTrue(state['routes']['Drone']['ok'])

    def test_actual_new_route_to_same_goal_inside_window_can_complete(self):
        state=self._state(); state['active_intents']=[self._intent(990,[17.5,17.5])]
        self._consume(state,self._event(1,1000,[17.5,17.5]))
        state=self._roundtrip(state)
        state['active_intents']=[self._intent(1001,[17.5,17.5])]
        state['routes']={'Drone':{'ok':True,'last_replan_tick':1001,'relay_point':[17.5,17.5]}}
        self._consume(state,self._event(2,1002,[17.5,17.5]))
        self.assertEqual(state['active_intents'][0]['state'],'completed')
        self.assertFalse(state['routes']['Drone']['ok'])

    def test_old_fact_does_not_close_intent_issued_after_it_without_route(self):
        state=self._state(); state['active_intents']=[self._intent(1010,[17.5,17.5])]
        self._consume(state,self._event(1,1000,[17.5,17.5]))
        self.assertEqual(state['active_intents'][0]['state'],'active')
        self.assertNotIn('effective_tick',state['active_intents'][0])

    def test_duplicate_releases_only_old_unclosed_segment(self):
        state=self._state(); self._consume(state,self._event(1,1000,[17.5,17.5]))
        state=self._roundtrip(state)
        state['active_intents']=[self._intent(990,[17.5,17.5]), self._intent(1001,[30,17.5])]
        self._consume(state,self._event(2,1002,[17.5,17.5]))
        self.assertEqual([r['state'] for r in state['active_intents']],['completed','active'])

    def test_legacy_list_migrates_without_permanently_suppressing_goal(self):
        state=self._state(); state['seen_arrivals']=['Drone|[17.5, 17.5]']
        state=self._roundtrip(state); state['active_intents']=[self._intent(990,[17.5,17.5])]
        self._consume(state,self._event(1,1000,[17.5,17.5]))
        self.assertEqual(state['active_intents'][0]['state'],'completed')
        self.assertIsInstance(state['seen_arrivals'],dict)

    def test_same_tick_many_units_keep_timestamp_memory_bounded(self):
        state=self._state()
        for seq in range(300):
            event=self._event(seq+1,1000,[17.5,17.5]);event['unit']='Drone-%s' % seq
            self._consume(state,event)
        self.assertLessEqual(len(state['seen_arrivals']),256)
        self.assertEqual(self._roundtrip(state)['seen_arrivals'],state['seen_arrivals'])

    def test_delayed_failed_goal_cannot_invalidate_new_route(self):
        state=self._state()
        state['routes']={'Drone':{'ok':True,'last_replan_tick':1001,'relay_point':[30,17.5]}}
        event=self._event(1,1000,[17.5,17.5]);event['kind']='path_failed'
        self._consume(state,event)
        self.assertTrue(state['routes']['Drone']['ok'])
        self.assertEqual(state.get('movement_urgent',[]),[])

    def test_old_failed_same_goal_is_rejected_by_fact_time(self):
        state=self._state()
        state['routes']={'Drone':{'ok':True,'last_replan_tick':1001,'relay_point':[17.5,17.5]}}
        event=self._event(1,1000,[17.5,17.5]);event['kind']='path_failed'
        self._consume(state,event)
        self.assertTrue(state['routes']['Drone']['ok'])
        self.assertEqual(state.get('movement_urgent',[]),[])

    def test_failed_other_goal_without_timestamp_is_stale(self):
        state=self._state()
        state['routes']={'Drone':{'ok':True,'last_replan_tick':990,'relay_point':[30,17.5]}}
        event=self._event(1,0,[17.5,17.5]);event['kind']='path_failed'
        self._consume(state,event)
        self.assertTrue(state['routes']['Drone']['ok'])

    def test_current_failed_route_still_enters_urgent_line(self):
        state=self._state()
        state['routes']={'Drone':{'ok':True,'last_replan_tick':990,'relay_point':[17.5,17.5]}}
        event=self._event(1,1000,[17.5,17.5]);event['kind']='path_failed'
        self._consume(state,event)
        self.assertFalse(state['routes']['Drone']['ok'])
        restored=self._roundtrip(state)
        self.assertEqual(restored['movement_urgent'][-1]['kind'],'path_failed')
        self.assertTrue(any(e['kind']=='path_failed' for e in restored['pending_events']))


if __name__=='__main__':
    unittest.main()
